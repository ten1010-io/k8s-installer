from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

from ansible.module_utils.basic import AnsibleModule


def main():
    module_args = {
        'ip_address_pools': {
            'type': 'list',
            'required': True
        },
        'node_name_to_k8s_hostname_map': {
            'type': 'dict',
            'required': True
        }
    }

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=False
    )

    ip_address_pools = module.params['ip_address_pools']
    node_name_to_k8s_hostname_map = module.params['node_name_to_k8s_hostname_map']

    pool_names = set()
    for ip_address_pool in ip_address_pools:
        if ip_address_pool['pool_name'] in pool_names:
            module.fail_json(msg="pool name '{}' duplicated".format(ip_address_pool['pool_name']))
        pool_names.add(ip_address_pool['pool_name'])
        for node in ip_address_pool['nodes']:
            if node not in node_name_to_k8s_hostname_map.keys():
                module.fail_json(msg="Node '{}' does not exist in node_name_to_k8s_hostname_map.keys()".format(node))
    module.exit_json()


if __name__ == '__main__':
    main()
