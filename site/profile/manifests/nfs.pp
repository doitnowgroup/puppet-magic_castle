class profile::nfs (String $domain) {
  $server = lookup('profile::nfs::client::server', undef, undef, '')
  $ipaddress = lookup('terraform.self.local_ip')

  if ($ipaddress == $server) or ($facts['networking']['fqdn'] == $server) or ($facts['networking']['hostname'] == $server) {
    include profile::nfs::server
  } elsif $server != '' {
    include profile::nfs::client
  } else {
    class { 'nfs':
      client_enabled => true,
    }
  }
}

class profile::nfs::client (
  Stdlib::Host $server,
  Array[String] $share_names = [],
) {
  $nfs_domain = lookup('profile::nfs::domain')
  class { 'nfs':
    client_enabled => true,
  }

  $instances = lookup('terraform.instances')
  if $server =~ Stdlib::IP::Address {
    $server_values = $instances.filter| $key, $values | { $values['local_ip'] == $server }.map | $key, $values | { $values }
  } elsif $server =~ Stdlib::Fqdn {
    $server_values = $instances.filter| $key, $values | { "${key}.${nfs_domain}" == $server }.map | $key, $values | { $values }
  } elsif $instances[$server] != undef {
    $server_values = [$instances[$server]]
  } else {
    $server_values = []
  }

  if length($server_values) > 0 {
    $nfs_volumes = $server_values.get('0.volumes.nfs', {})
    $shares_to_mount = keys($nfs_volumes) + $share_names
    $nfs_options     = 'proto=tcp,nosuid,nolock,noatime,actimeo=3,nfsvers=4.2,seclabel,_netdev'
  } else {
    # The NFS server is not an instance created and managed by Magic Castle(Terraform).
    $shares_to_mount = $share_names
    case $facts['cloud']['provider'] {
      'aws': {
        # https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html
        $nfs_options = 'nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport'
      }
      default: {
        $nfs_options = 'defaults'
      }
    }
  }

  $self_volumes = lookup('terraform.self.volumes')
  if $facts['virtual'] =~ /^(container|lxc).*$/ {
    # automount relies on a kernel module that currently does not support namespace.
    # Therefore it is not compatible with containers.
    # https://superuser.com/a/1372700
    $mount_options = 'x-systemd.mount-timeout=infinity,retry=10000,fg'
  } else {
    $mount_options = 'x-systemd.automount,x-systemd.mount-timeout=30'
  }

  ensure_resource('systemd::daemon_reload', 'nfs-client')
  exec { 'systemctl restart remote-fs.target':
    subscribe   => Systemd::Daemon_reload['nfs-client'],
    refreshonly => true,
    tries       => 20, # trye to connect the nfs mounts for 5 minutes
    try_sleep   => 15,
    path        => ['/bin', '/usr/bin'],
  }

  $options_nfsv4 = join([$nfs_options, $mount_options], ',')
  $shares_to_mount.each | String $share_name_raw | {
    $share_name = regsubst($share_name_raw, '^/|/$', '', 'G')
    $mount_point = "/nfs/${share_name}"
    nfs::client::mount { $mount_point:
      ensure        => present,
      server        => $server,
      share         => $share_name,
      options_nfsv4 => $options_nfsv4,
      notify        => Systemd::Daemon_reload['nfs-client'],
    }
    # If the instance has a volume mounted under the same name as the nfs share,
    # we only mount the nfs share under /nfs/${share_name}. Otherwise, we create
    # a mount bind to /${share_name}.
    if ! $self_volumes.any |$tag, $volume_hash| { $share_name in $volume_hash } {
      ensure_resource('file', "/${share_name}", { 'ensure' => 'directory' })
      mount { "/${share_name}":
        ensure  => present,
        device  => $mount_point,
        fstype  => none,
        options => 'bind,x-systemd.automount',
        require => [
          File["/${share_name}"],
          Nfs::Client::Mount[$mount_point],
        ],
        notify  => Systemd::Daemon_reload['nfs-client'],
      }
      -> service { "${share_name}.automount":
        ensure => running,
      }
    }
  }
}

class profile::nfs::server (
  Array[String] $no_root_squash_tags = ['mgmt'],
  Boolean $enable_client_quotas = false,
  Array[String] $export_paths = [],
) {
  include profile::volumes

  $nfs_domain = lookup('profile::nfs::domain')
  class { 'nfs':
    server_enabled => true,
  }

  file { '/etc/nfs.conf':
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => 'puppet:///modules/profile/nfs/nfs.conf',
    notify => Service[$nfs::server_service_name],
  }

  if $enable_client_quotas {
    package { 'quota-rpc':
      ensure => 'installed',
    }
    service { 'rpc-rquotad':
      ensure  => 'running',
      enable  => true,
      require => [Service['rpcbind'], Service['rpcbind.socket'], Package['quota-rpc']]
    }
    service { ['rpcbind', 'rpcbind.socket']:
      enable => true,
      notify => Service[$nfs::server_service_name],
    }
  }
  else {
    service { ['rpcbind', 'rpcbind.socket']:
      ensure => stopped,
      enable => mask,
      notify => Service[$nfs::server_service_name],
    }
  }
  service { 'rpc-statd':
    ensure => stopped,
    enable => mask,
    notify => Service[$nfs::server_service_name],
  }

  $devices = lookup('terraform.self.volumes.nfs', Hash, undef, {})
  if $devices =~ Hash[String, Hash] {
    $export_path_list = $export_paths + $devices.map | String $key, $glob | { "/mnt/nfs/${key}" }
  } else {
    $export_path_list = $export_paths
  }
  $export_paths.each |$path| {
    ensure_resource('file', $path, { ensure => directory, before => Nfs::Server::Export[$path] })
  }

  # Pre-create the shared EESSI host_injections directory server-side.
  #
  # profile::software_stack::eessi_host_injections holds a client path such as
  # /project/eessi. Clients mount this share and their root is root-squash, so a
  # node cannot create the directory itself. This class runs on the NFS server,
  # whose tag is in $no_root_squash_tags, so this run is not squashed.
  #
  # The directory is created only when the volume it lives on is declared in
  # terraform.self.volumes.nfs. Otherwise nothing is required and no
  # Profile::Volumes::Volume resource is referenced, which keeps clusters
  # without a matching volume compiling.
  #
  # Set profile::nfs::server::eessi_host_injections_group to a group name to
  # give users write access to it; it stays root-owned when unset.
  $eessi_host_injections = lookup('profile::software_stack::eessi_host_injections', String, undef, '/opt/eessi')
  if $eessi_host_injections =~ '^/[A-Za-z0-9]' and $eessi_host_injections !~ '^/mnt/nfs' {
    $eessi_host_injections_volume = $eessi_host_injections.split('/').filter |$chunk| { $chunk != '' }[0]
    if $eessi_host_injections_volume in $devices {
      $eessi_host_injections_group = lookup('profile::nfs::server::eessi_host_injections_group', Optional[String], undef, undef)
      if $eessi_host_injections_group {
        $eessi_host_injections_attrs = {
          ensure  => directory,
          owner   => 'root',
          group   => $eessi_host_injections_group,
          mode    => '2775',
          require => Profile::Volumes::Volume["nfs-${eessi_host_injections_volume}"],
        }
      } else {
        $eessi_host_injections_attrs = {
          ensure  => directory,
          mode    => '0755',
          require => Profile::Volumes::Volume["nfs-${eessi_host_injections_volume}"],
        }
      }
      file { "/mnt/nfs${eessi_host_injections}":
        * => $eessi_host_injections_attrs,
      }
    }
  }

  if $export_path_list {
    # Allow instances with specific tags to mount NFS without root squash
    $instances = lookup('terraform.instances')
    $common_options = 'rw,async,no_all_squash,security_label'
    $prefixes  = $instances.filter|$key, $values| { ! intersection($values['tags'], $no_root_squash_tags ).empty }.map|$key, $values| { $values['prefix'] }.unique
    $prefix_rules = $prefixes.map|$string| { "${string}*.${nfs_domain}(${common_options},no_root_squash)" }.join(' ')
    $clients = "${prefix_rules} *.${nfs_domain}(${common_options},root_squash)"
    $export_path_list.each | String $path| {
      nfs::server::export { $path:
        ensure  => 'mounted',
        clients => $clients,
        notify  => Service[$nfs::server_service_name],
        require => Class['nfs'],
      }
    }
  }
  Profile::Volumes::Volume<| |> -> Nfs::Server::Export <| |>
  Mount <| |> -> Service <| tag == 'profile::accounts' and title == 'mkhome' |>
  Mount <| |> -> Service <| tag == 'profile::accounts' and title == 'mkproject' |>
}
