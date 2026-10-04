servers = {
  "load-balancer" => { ip: "192.168.56.10", memory: 512,  cpus: 1 },
  "web-server-1"  => { ip: "192.168.56.11", memory: 1024, cpus: 1 },
  "web-server-2"  => { ip: "192.168.56.12", memory: 1024, cpus: 1 },
  "app-server"    => { ip: "192.168.56.13", memory: 1024, cpus: 1 },
  "backup-server" => { ip: "192.168.56.14", memory: 512,  cpus: 1 },
  "ci-server"     => { ip: "192.168.56.15", memory: 2048, cpus: 2 },
  # Prometheus, Grafana, 2x Elasticsearch, Logstash, Kibana (all in containers)
  "monitoring-server" => { ip: "192.168.56.16", memory: 4096, cpus: 2 },
}

Vagrant.configure("2") do |config|
  servers.each do |server_name, cfg|
    config.vm.define server_name do |node|
      node.vm.box      = "ubuntu/jammy64"
      node.vm.hostname = server_name
      node.vm.network "private_network", ip: cfg[:ip]
      node.vm.synced_folder ".", "/vagrant"

      node.vm.boot_timeout = 600

      node.vm.provider "virtualbox" do |vb|
        vb.name   = server_name
        vb.memory = cfg[:memory]
        vb.cpus   = cfg[:cpus]
      end

      node.vm.provision "ansible_local" do |ansible|
        ansible.playbook       = "ansible/site.yml"
        ansible.inventory_path = "ansible/inventory.ini"
        ansible.install        = true
        ansible.limit          = "all"
      end
    end
  end
end
