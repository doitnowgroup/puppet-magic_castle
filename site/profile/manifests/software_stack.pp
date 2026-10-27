class profile::software_stack (
  Integer $min_uid = 1000,
  Optional[String] $initial_profile = undef,
  Optional[Array[String]] $lmod_default_modules = undef,
  Optional[Hash[String, String]] $extra_site_env_vars = undef,
  String $eessi_host_injections = '/opt/eessi',
  String $eessi_nvidia_override_default = '/opt/eessi/nvidia',
) {
  include profile::consul
  include profile::cvmfs::client

  package { 'cvmfs-config-eessi':
    ensure   => 'installed',
    provider => 'rpm',
    require  => Package['cvmfs'],
    source   => 'https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm',
  }

  package { 'computecanada-release-2.0-1.noarch':
    ensure   => 'installed',
    provider => 'rpm',
    source   => 'https://package.computecanada.ca/yum/cc-cvmfs-public/prod/RPM/computecanada-release-2.0-1.noarch.rpm',
  }

  package { 'cvmfs-config-computecanada':
    ensure  => 'installed',
    require => [
      Package['cvmfs'],
      Package['computecanada-release-2.0-1.noarch']
    ],
  }

  if $facts['software_stack'] == 'computecanada' or $facts['software_stack'] == 'alliance' {
    if $facts['os']['architecture'] != 'x86_64' {
      fail("${facts['software_stack']} software stack does not support: ${facts['os']['architecture']}")
    }

    file { '/etc/consul-template/z-00-rsnt_arch.sh.ctmpl':
      source => 'puppet:///modules/profile/software_stack/z-00-rsnt_arch.sh.ctmpl',
      notify => Service['consul-template'],
    }

    consul_template::watch { 'z-00-rsnt_arch.sh':
      require     => File['/etc/consul-template/z-00-rsnt_arch.sh.ctmpl'],
      config_hash => {
        perms       => '0644',
        source      => '/etc/consul-template/z-00-rsnt_arch.sh.ctmpl',
        destination => '/etc/profile.d/z-00-rsnt_arch.sh',
        command     => '/usr/bin/true',
      },
    }
    $software_stack_meta = { arch => $facts['cpu_ext'] }
  } else {
    file { '/etc/profile.d/z-00-rsnt_arch.sh':
      ensure => 'absent',
    }
    $software_stack_meta = {}
  }

  $ensure_stack = $facts['software_stack'] ? {
    'computecanada' => 'present',
    'alliance'      => 'present',
    'eessi'         => 'present',
    default         => 'absent',
  }

  file { '/etc/profile.d/z-01-site.sh':
    ensure  => $ensure_stack,
    content => epp('profile/software_stack/z-01-site.sh',
      {
        'min_uid'              => $min_uid,
        'lmod_default_modules' => $lmod_default_modules,
        'initial_profile'      => $initial_profile,
        'extra_site_env_vars'  => $extra_site_env_vars,
      }
    ),
  }

  if $facts['software_stack'] == 'eessi' {
    # EESSI reads two independent variant symlinks out of the local CernVM-FS
    # configuration. They are deliberately pointed at DIFFERENT paths:
    #
    #   EESSI_HOST_INJECTIONS
    #     -> /cvmfs/software.eessi.io/host_injections
    #     Site-wide installs: the CUDA/cuDNN SDK, the 2023.06 layout, site MPI
    #     overrides. This one belongs on shared storage, so a site install is
    #     done once per architecture instead of once per node.
    #
    #   EESSI_NVIDIA_OVERRIDE_DEFAULT
    #     -> /cvmfs/software.eessi.io/versions/<version>/compat/<os>/<arch>/lib/nvidia
    #     Host driver libraries only. EESSI >= 2025.06 finds the host drivers
    #     there (the target is /dev/null when unset, i.e. no GPU support).
    #     Driver versions differ per node type, so this stays node-local.
    #     profile::gpu::install populates that directory when its
    #     lib_symlink_path is set to the same path (see
    #     data/software_stack/eessi.yaml).
    #
    # www.eessi.io/docs/site_specific_config/host_injections/
    # www.eessi.io/docs/site_specific_config/gpu/
    $eessi_cvmfs_keys = [
      "EESSI_HOST_INJECTIONS=${eessi_host_injections}",
      "EESSI_NVIDIA_OVERRIDE_DEFAULT=${eessi_nvidia_override_default}",
    ]

    file { '/etc/cvmfs/config.d/software.eessi.io.local':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => $eessi_cvmfs_keys.map |String $key| { "${key}\n" }.join,
      require => Package['cvmfs-config-eessi'],
      notify  => Exec['cvmfs_reload_eessi'],
    }

    exec { 'cvmfs_reload_eessi':
      command     => '/usr/bin/cvmfs_config reload software.eessi.io',
      refreshonly => true,
      path        => ['/usr/bin'],
      require     => Package['cvmfs'],
    }
  }

  @consul::service { 'software_stack':
    ensure => $ensure_stack,
    meta   => $software_stack_meta,
  }
}
