from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

from ansible.module_utils.basic import AnsibleModule


def main():
    module_args = {
        'k8s_ip_to_node_name_map': {
            'type': 'dict',
            'required': True
        },
        'k8s_hostname_to_addresses_map': {
            'type': 'dict',
            'required': True
        }
    }

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=False
    )

    k8s_ip_to_node_name_map = module.params['k8s_ip_to_node_name_map']
    k8s_hostname_to_addresses_map = module.params['k8s_hostname_to_addresses_map']

    node_name_to_k8s_hostname_map = {}
    for k, v in k8s_hostname_to_addresses_map.items():
        for e in v:
            if e in k8s_ip_to_node_name_map.keys():
                node_name_to_k8s_hostname_map.update({k8s_ip_to_node_name_map[e]: k})
                break
    k8s_hostname_to_node_name_map = {}
    for k, v in node_name_to_k8s_hostname_map.items():
        k8s_hostname_to_node_name_map.update({v: k})

    module.exit_json(node_name_to_k8s_hostname_map=node_name_to_k8s_hostname_map,
                     k8s_hostname_to_node_name_map=k8s_hostname_to_node_name_map)


if __name__ == '__main__':
    main()
