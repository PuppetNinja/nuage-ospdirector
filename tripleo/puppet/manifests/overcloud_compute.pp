# Copyright 2014 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

include tripleo::packages

create_resources(sysctl::value, hiera('sysctl_settings'), {})

if count(hiera('ntp::servers')) > 0 {
  include ::ntp
}

file { ['/etc/libvirt/qemu/networks/autostart/default.xml',
        '/etc/libvirt/qemu/networks/default.xml']:
  ensure => absent,
  before => Service['libvirt']
}
# in case libvirt has been already running before the Puppet run, make
# sure the default network is destroyed
exec { 'libvirt-default-net-destroy':
  command => '/usr/bin/virsh net-destroy default',
  onlyif => '/usr/bin/virsh net-info default | /bin/grep -i "^active:\s*yes"',
  before => Service['libvirt'],
}

include ::nova
include ::nova::config
include ::nova::compute

nova_config {
  'DEFAULT/my_ip':                     value => $ipaddress;
  'DEFAULT/linuxnet_interface_driver': value => 'nova.network.linux_net.LinuxOVSInterfaceDriver';
}

$nova_enable_rbd_backend = hiera('nova_enable_rbd_backend', false)
if $nova_enable_rbd_backend {
  include ::ceph::profile::client

  $client_keys = hiera('ceph::profile::params::client_keys')
  $client_user = join(['client.', hiera('ceph_client_user_name')])
  class { '::nova::compute::rbd':
    libvirt_rbd_secret_key => $client_keys[$client_user]['secret'],
  }
}

if hiera('cinder_enable_nfs_backend', false) {
  if ($::selinux != "false") {
    selboolean { 'virt_use_nfs':
        value => on,
        persistent => true,
    } -> Package['nfs-utils']
  }

  package {'nfs-utils': } -> Service['nova-compute']
}

include ::nova::compute::libvirt
include ::nova::network::neutron
include ::neutron

# If the value of core plugin is set to 'nuage',
# include nuage agent,
# else use the default value of 'ml2'
if hiera('neutron::core_plugin') == 'neutron.plugins.nuage.plugin.NuagePlugin' {
  include ::nuage::vrs
  include ::nova::compute::neutron

  class { '::nuage::metadataagent':
    nova_os_tenant_name => hiera('nova::api::admin_tenant_name'),
    nova_os_password    => hiera('nova_password'),
    nova_metadata_ip    => hiera('nova_metadata_node_ips'),
    nova_auth_ip        => hiera('keystone_public_api_virtual_ip'),
  }
} else {
  class { 'neutron::plugins::ml2':
    flat_networks        => split(hiera('neutron_flat_networks'), ','),
    tenant_network_types => [hiera('neutron_tenant_network_type')],
  }

  class { 'neutron::agents::ml2::ovs':
    bridge_mappings => split(hiera('neutron_bridge_mappings'), ','),
    tunnel_types    => split(hiera('neutron_tunnel_types'), ','),
  }

  if 'cisco_n1kv' in hiera('neutron_mechanism_drivers') {
    class { 'neutron::agents::n1kv_vem':
      n1kv_source          => hiera('n1kv_vem_source', undef),
      n1kv_version         => hiera('n1kv_vem_version', undef),
    }
  }
}


include ::ceilometer
include ::ceilometer::agent::compute
include ::ceilometer::agent::auth

$snmpd_user = hiera('snmpd_readonly_user_name')
snmp::snmpv3_user { $snmpd_user:
  authtype => 'MD5',
  authpass => hiera('snmpd_readonly_user_password'),
}
class { 'snmp':
  agentaddress => ['udp:161','udp6:[::1]:161'],
  snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
}

# jmdiel : using newly created ceph_mon parameter
if str2bool(hiera('enable_ceph_mon', 'false')) {
  class { 'ceph::profile::params':
    mon_initial_members => downcase(hiera('ceph_mon_initial_members'))
  }
  include ::ceph::profile::mon
}

# jmdiel : adding ceph osd
if str2bool(hiera('enable_ceph_storage', 'false')) {
  if str2bool(hiera('ceph_osd_selinux_permissive', true)) {
    exec { 'set selinux to permissive on boot':
      command => "sed -ie 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config",
      onlyif  => "test -f /etc/selinux/config && ! grep '^SELINUX=permissive' /etc/selinux/config",
      path    => ["/usr/bin", "/usr/sbin"],
    }

    exec { 'set selinux to permissive':
      command => "setenforce 0",
      onlyif  => "which setenforce && getenforce | grep -i 'enforcing'",
      path    => ["/usr/bin", "/usr/sbin"],
    } -> Class['ceph::profile::osd']
  }

  include ::ceph::profile::osd
}
# jmdiel : adding ceph osd

package_manifest{'/var/lib/tripleo/installed-packages/overcloud_compute': ensure => present}
