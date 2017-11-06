module Forklift
  class BoxDistributor

    VAGRANTFILE_API_VERSION = '2'.freeze

    if Gem.loaded_specs['vagrant']
      SUPPORT_SSH_INSERT_KEY = Gem.loaded_specs['vagrant'].version >= Gem::Version.create('1.7')
      SUPPORT_NAMED_PROVISIONERS = Gem.loaded_specs['vagrant'].version >= Gem::Version.create('1.7')
      SUPPORT_BOX_CHECK_UPDATE = Gem.loaded_specs['vagrant'].version >= Gem::Version.create('1.5')
    end

    def initialize(boxes)
      @ansible_groups = {}
      @boxes = boxes
      @boxes = @boxes.keys.sort.each_with_object({}) do |key, hash|
        hash[key] = @boxes[key]
        hash
      end
      @settings = settings
    end

    def settings
      overrides = {}
      settings_file = "#{File.dirname(__FILE__)}/../../settings.yaml"
      default_settings = {
        'memory' => 6144,
        'cpus' => 2,
        'scale_memory' => 1,
        'scale_cpus' => 1,
        'sync_type' => 'rsync',
        'cachier' => {
          'mount_options' => ['rw', 'vers=3', 'tcp', 'nolock']
        }
      }

      overrides = YAML.load_file(settings_file) if File.exist?(settings_file)

      @settings ||= default_settings.merge(overrides)
    end

    def distribute
      Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
        configure_vagrant_hostmanager(config)
        configure_vagrant_cachier(config)

        @boxes.each_value do |box|
          define_vm config, box
        end

        config.vm.provider :libvirt do |domain|
          domain.memory = @settings['memory']
          domain.cpus   = @settings['cpus']
        end

        config.vm.provider :virtualbox do |domain|
          domain.memory = @settings['memory']
          domain.cpus   = @settings['cpus']
          domain.customize ['modifyvm', :id, '--natdnsproxy1', 'off']
          domain.customize ['modifyvm', :id, '--natdnshostresolver1', 'off']
        end
      end
    end

    def define_vm(config, box = {})
      primary = box.fetch('primary', false)
      autostart = box.fetch('autostart', false)
      config.vm.define box.fetch('name'), primary: primary, autostart: autostart do |machine|
        machine.vm.box = box.fetch('box_name')
        config.ssh.insert_key = false if SUPPORT_SSH_INSERT_KEY
        config.ssh.forward_agent = box.fetch('ssh_forward_agent', nil) || @settings.fetch('ssh_forward_agent', false)
        machine.vm.box_check_update = true if SUPPORT_BOX_CHECK_UPDATE

        machine.vm.box_url = box.fetch('box_url') if box.key?('box_url')

        domain = create_domain(box)

        machine.vm.hostname = if box.fetch('hostname', false)
                                box.fetch('hostname')
                              else
                                "#{box.fetch('name').to_s.tr('.', '-')}.#{domain}"
                              end

        networks = configure_networks(box.fetch('networks', []))
        configure_shell(machine, box)
        configure_ansible(machine, box['ansible'], box['name'])
        configure_libvirt(machine, box, networks)
        configure_virtualbox(machine, box)
        configure_rackspace(machine, box)
        configure_synced_folders(machine, box)
        configure_sshfs(config, box)

        yield machine if block_given?
      end
    end

    def create_domain(box)
      box['domain'] || @settings['domain'] || "#{`hostname -s`.strip}.example.com"
    end

    def configure_sshfs(config, box)
      return unless box['sshfs']
      config.vm.synced_folder box['sshfs']['host_path'],
                              box['sshfs']['guest_path'],
                              :type => :sshfs,
                              :reverse => box['sshfs']['reverse'] || false
    end

    def configure_vagrant_hostmanager(config)
      return unless Vagrant.has_plugin?('vagrant-hostmanager')
      config.hostmanager.enabled = true
      config.hostmanager.manage_host = true
      config.hostmanager.manage_guest = true
      config.hostmanager.include_offline = true
    end

    def configure_vagrant_cachier(config)
      return unless Vagrant.has_plugin?('vagrant-cachier')
      config.cache.scope = :box
      config.cache.synced_folder_opts = {
        type: :nfs,
        mount_options: @settings['cachier']['mount_options']
      }
    end

    def configure_networks(networks)
      return [] if networks.empty?
      networks.map do |network|
        network.update('options' => symbolized_options(network['options']))
      end
    end

    def configure_ansible(machine, ansible, box_name)
      return unless ansible

      if ansible.key?('group') || !ansible['group'].nil?
        unless @ansible_groups[ansible['group'].to_s]
          @ansible_groups[ansible['group'].to_s] = []
        end

        @ansible_groups[ansible['group'].to_s] << box_name
      end

      if ansible.key?('server') || !ansible['server'].nil?
        @ansible_groups["server-#{box_name}"] = ansible['server']
      end

      return unless (playbooks = ansible['playbook'])

      [playbooks].flatten.each_with_index do |playbook, index|
        args = SUPPORT_NAMED_PROVISIONERS ? ["main#{index}", type: 'ansible'] : [:ansible]
        machine.vm.provision(*args) do |ansible_provisioner|
          ansible_provisioner.playbook = playbook
          ansible_provisioner.extra_vars = ansible['variables']
          ansible_provisioner.groups = @ansible_groups
          ansible_provisioner.verbose = ansible['verbose'] ? ansible['verbose'] : false
        end
      end
    end

    def configure_shell(machine, box)
      return unless box.key?('shell') && !box['shell'].nil?
      machine.vm.provision :shell do |shell|
        shell.inline = box.fetch('shell')
        shell.privileged = false if box.key?('privileged')
      end
    end

    # Configures synced folders defined for the box
    # and the private network required for them
    def configure_synced_folders(machine, box)
      synced_folders = box.fetch('synced_folders', [])
      return if synced_folders.empty?
      configure_private_network(machine, box)

      synced_folders.each do |folder|
        machine.vm.synced_folder folder['path'], folder['mount_point'], symbolized_options(folder['options'])
      end
    end

    def configure_private_network(machine, box)
      ip = box.fetch('private_ip', nil)
      options = {}.tap do |hash|
        if ip
          hash[:ip] = ip
        else
          hash[:type] = 'dhcp'
        end
      end
      machine.vm.network :private_network, options
    end

    def configure_libvirt(machine, box, networks = [])
      machine.vm.provider :libvirt do |p, override|
        override.vm.box_url = box.fetch('libvirt') if box.fetch('libvirt', false)
        override.vm.synced_folder '.', '/vagrant', type: @settings['sync_type'], rsync__args: ['--max-size=100m']

        bridged = box.fetch('bridged', false)
        if bridged
          override.vm.network :public_network, :dev => bridged, :mode => 'bridge'
        end
        configure_forwarded_ports(box, override, bridged)
        networks.each do |network|
          override.vm.network network['type'], network['options']
        end
        p.cpus = box.fetch('cpus').to_i * @settings['scale_cpus'].to_i if box.fetch('cpus', false)
        p.memory = box.fetch('memory').to_i * @settings['scale_memory'].to_i if box.fetch('memory', false)
        p.machine_virtual_size = box.fetch('disk_size') if box.fetch('disk_size', false)

        box.fetch('libvirt_options', []).each do |opt, val|
          p.instance_variable_set("@#{opt}", val)
        end
      end
    end

    def configure_virtualbox(machine, box)
      machine.vm.provider :virtualbox do |p, override|
        override.vm.box_url = box.fetch('virtualbox') if box.fetch('virtualbox', false)
        p.cpus = box.fetch('cpus').to_i * @settings['scale_cpus'].to_i if box.fetch('cpus', false)
        p.memory = box.fetch('memory').to_i * @settings['scale_memory'].to_i if box.fetch('memory', false)

        bridged = box.fetch('bridged', false)
        override.vm.network :public_network, bridge: bridged if bridged

        configure_forwarded_ports(box, override, bridged)

        box.fetch('virtualbox_options', []).each do |opt, val|
          p.instance_variable_set("@#{opt}", val)
        end
      end
    end

    def configure_rackspace(machine, box)
      return unless box.fetch('image_name', false)
      machine.vm.provider :rackspace do |p, override|
        override.vm.box  = 'dummy'
        p.server_name    = machine.vm.hostname
        p.flavor         = /4GB/
        p.image          = box.fetch('image_name')
        override.ssh.pty = true if box.fetch('pty')

        box.fetch('rackspace_options', []).each do |opt, val|
          p.instance_variable_set("@#{opt}", val)
        end
      end
    end

    private

    def symbolized_options(hash)
      hash.inject({}) { |memo, (k, v)| memo.update(k.to_sym => v) }
    end

    def configure_forwarded_ports(box, override, bridged)
      return if bridged
      host_ip = box.fetch('ansible', {}).fetch('variables', {}).fetch('forwarded_port_host_ip', '127.0.0.1')
      if box.fetch('name').to_s.include?('devel')
        override.vm.network :forwarded_port, guest: 3000, host: 3330, host_ip: host_ip
        override.vm.network :forwarded_port, guest: 3808, host: 3808, host_ip: host_ip
        override.vm.network :forwarded_port, guest: 443, host: 4430, host_ip: host_ip
      else
        override.vm.network :forwarded_port, guest: 80, host: 8080, host_ip: host_ip
        override.vm.network :forwarded_port, guest: 443, host: 4433, host_ip: host_ip
      end
    end

  end
end
