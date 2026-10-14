# Memory is sized so that all 7 VMs (~9 GB) fit on a 16 GB host.
# Every VM also gets a 1 GB swap file (common role) to survive short peaks
# such as Docker image builds or Kibana start-up.
servers = {
  "load-balancer" => { ip: "192.168.56.10", memory: 512,  cpus: 1 },
  "web-server-1"  => { ip: "192.168.56.11", memory: 640,  cpus: 1 },
  "web-server-2"  => { ip: "192.168.56.12", memory: 640,  cpus: 1 },
  "app-server"    => { ip: "192.168.56.13", memory: 768,  cpus: 1 },
  "backup-server" => { ip: "192.168.56.14", memory: 512,  cpus: 1 },
  "ci-server"     => { ip: "192.168.56.15", memory: 1536, cpus: 2 },
  # Prometheus, Grafana, 2x Elasticsearch, Logstash, Kibana (all in containers);
  # the stack uses ~3.4 GB, with less RAM the JVMs + Kibana swap and time out (and the VM
  # itself would sit near the 90% memory alert); 4 vCPUs because
  # 2 ES nodes + Logstash + Kibana all start at once when the VM boots
  "monitoring-server" => { ip: "192.168.56.16", memory: 4608, cpus: 4 },
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
