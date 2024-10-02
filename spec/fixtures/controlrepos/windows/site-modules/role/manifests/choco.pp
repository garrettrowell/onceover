# Choco
class role::choco {
  class { 'chocolatey':
    chocolatey_version => '2.3.0',
  }


  package { 'winzip':
    ensure   => 'present',
    provider => 'chocolatey',
  }
}
