from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

from ansible.module_utils.basic import AnsibleModule


def main():
    module_args = {
        'node_addresses': {
            'type': 'list',
            'required': True
        }
    }

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=False
    )

    node_addresses = module.params['node_addresses']

    k8s_hostname_to_addresses_map = {}
    for e in node_addresses:
        k8s_hostname_to_addresses_map.update({e[0]: e[1:]})

    module.exit_json(k8s_hostname_to_addresses_map=k8s_hostname_to_addresses_map)


if __name__ == '__main__':
    main()
