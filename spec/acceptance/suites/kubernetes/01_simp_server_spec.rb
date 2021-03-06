require 'spec_helper_integration'
require 'beaker/puppet_install_helper'
require 'yaml'

# Create a Puppetfile for R10K from module
# portion of a simp-core Puppetfile.<tracking|stable>.
# Returns Puppetfile content
def create_r10k_puppetfile(simp_core_puppetfile)
  r10k_puppetfile = []
  lines = IO.readlines(simp_core_puppetfile)
  modules_section = false
  lines.each do |line|
     if line.match(/^moduledir/)
       if line.match(/^moduledir 'src\/puppet\/modules'/)
         modules_section = true
       else
         modules_section = false
       end
       next
     end
     r10k_puppetfile << line if modules_section
  end
  r10k_puppetfile.join  # each line already contains a \n
end

test_name 'puppetserver via r10k'

describe 'install environment via r10k and puppetserver' do

  masters     = hosts_with_role(hosts, 'master')
  agents      = hosts_with_role(hosts, 'agent')
  master_fqdn = fact_on(master, 'fqdn')
  master_manifest = <<-EOF
    # Set up a puppetserver
    class { 'pupmod::master':
      firewall     => true,
      trusted_nets => ['ALL'],
    }
    # pupmod::master::autosign { '*': entry => '*' }
    exec { 'set autosign':
      command => '/opt/puppetlabs/bin/puppet config --section master set autosign true',
      unless  => '/opt/puppetlabs/bin/puppet config --section master print autosign | grep true'
    }

    # Maintain connection to the VM
    pam::access::rule { 'vagrant_all':
      users      => ['vagrant'],
      permission => '+',
      origins    => ['ALL'],
    }
    sudo::user_specification { 'vagrant':
      user_list => ['vagrant'],
      cmnd      => ['ALL'],
      passwd    => false,
    }
    sshd_config { 'PermitRootLogin'    : value => 'yes' }
    sshd_config { 'AuthorizedKeysFile' : value => '.ssh/authorized_keys' }
    include 'tcpwrappers'
    include 'iptables'
    tcpwrappers::allow { 'sshd': pattern => 'ALL' }
    iptables::listen::tcp_stateful { 'allow_ssh':
      trusted_nets => ['ALL'],
      dports       => 22
    }
  EOF

  hosts.each do |host|
    it 'should set the root password' do
      on(host, "sed -i 's/enforce_for_root//g' /etc/pam.d/*")
      on(host, 'echo password | passwd root --stdin')
    end
    it 'should set up needed repositories' do
      host.install_package('epel-release')
      on(host, 'curl -s https://packagecloud.io/install/repositories/simp-project/6_X_Dependencies/script.rpm.sh | bash')
    end
    it 'should install the r10k gem' do
      master.install_package('git')
      on(master, 'puppet resource package r10k ensure=present provider=puppet_gem')
    end
  end

  context 'install and start a standard puppetserver' do
    masters.each do |master|
      it 'should install puppetserver' do
        master.install_package('puppetserver')
      end

      it 'should start puppetserver' do
        on(master, 'puppet resource service puppetserver ensure=running')
      end

      it 'should enable trusted_server_facts' do
        on(master, 'puppet config --section master set trusted_server_facts true')
      end
    end
  end

  context 'install modules via r10k' do
    it 'should create a Puppetfile in $codedir from Puppetfile.tracking' do
      file_content = create_r10k_puppetfile('Puppetfile.tracking')
      create_remote_file(master, '/etc/puppetlabs/code/environments/production/Puppetfile',
        file_content)
    end

    it 'should install the Puppetfile' do
      on(master, 'cd /etc/puppetlabs/code/environments/production; /opt/puppetlabs/puppet/bin/r10k puppetfile install', :accept_all_exit_codes => true)
      on(master, 'cd /etc/puppetlabs/code/environments/production; /opt/puppetlabs/puppet/bin/r10k puppetfile install')
      on(master, 'chown -R root.puppet /etc/puppetlabs/code/environments/production/modules')
      on(master, 'chmod -R g+rX /etc/puppetlabs/code/environments/production/modules')
    end
  end

  context 'bootstrap simp server' do
    it 'should set up a simp server' do
       apply_manifest_on(master, master_manifest, :accept_all_exit_codes => true)
       apply_manifest_on(master, master_manifest, :accept_all_exit_codes => true)
       master.reboot
       apply_manifest_on(master, master_manifest, :catch_failures => true)
     end
     it 'should be idempotent' do
       apply_manifest_on(master, master_manifest, :catch_changes => true )
     end
  end

  context 'classify nodes' do
    site_pp = <<-EOF
      node default {
        include 'simp'
      }
      node /puppet/ {
        include 'simp'
        include 'simp::server'
        include 'pupmod'
        include 'pupmod::master'
      }
    EOF

    default_hiera = YAML.load_file('spec/acceptance/suites/kubernetes/files/hieradata.yaml').merge({
        'simp_options::puppet::server' => master_fqdn,
        'simp_options::puppet::ca'     => master_fqdn,
        'simp::yum::servers'           => [master_fqdn],
      }
    )

    it 'should install the control repo' do
      on(master, 'mkdir -p /etc/puppetlabs/code/environments/production/{hieradata,manifests} /var/simp/environments/production/{simp_autofiles,site_files/modules/pki_files/files/keydist}')
      scp_to(master, 'spec/acceptance/suites/default/files/hiera.yaml', '/etc/puppetlabs/puppet/hiera.yaml')
      create_remote_file(master, '/etc/puppetlabs/code/environments/production/manifests/site.pp', site_pp)
      create_remote_file(master, '/etc/puppetlabs/code/environments/production/hieradata/default.yaml', default_hiera.to_yaml)
      on(master, 'chown -R root.puppet /etc/puppetlabs/code/environments/production/{hieradata,manifests} /var/simp/environments/production/site_files/modules/pki_files/files/keydist')
      on(master, 'chmod -R g+rX /etc/puppetlabs/code/environments/production/{hieradata,manifests} /var/simp/environments/production/site_files/modules/pki_files/files/keydist')
      on(master, 'chown -R puppet.puppet /var/simp/environments/production/simp_autofiles')
      on(master, 'puppet resource service puppetserver ensure=running')
    end
  end

  context 'agents' do
    agents.each do |agent|
      it 'should run the agent' do
        # require 'pry';binding.pry if fact_on(agent, 'hostname') == 'agent'
        on(agent, "puppet agent -t --ca_port 8141 --server #{master_fqdn}",
          acceptable_exit_codes: [0,2,4,6],
          run_in_parallel: true
        )
        Simp::TestHelpers.wait(30)
        on(agent, "puppet agent -t --ca_port 8141 --server #{master_fqdn}",
          acceptable_exit_codes: [0,2,4,6],
          run_in_parallel: true )
        agent.reboot
        Simp::TestHelpers.wait(240)
        on(agent, "puppet agent -t --ca_port 8141 --server #{master_fqdn}",
          acceptable_exit_codes: [0,2],
          run_in_parallel: true )
      end
      it 'should be idempotent' do
        Simp::TestHelpers.wait(30)
        on(agent, 'puppet agent -t',
          acceptable_exit_codes: [0],
          run_in_parallel: true )
      end
    end
  end

end
