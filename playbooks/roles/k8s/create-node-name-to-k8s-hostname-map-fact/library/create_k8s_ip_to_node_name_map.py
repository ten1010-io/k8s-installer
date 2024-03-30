from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

from ansible.module_utils.basic import AnsibleModule


def main():
    module_args = {
        'hostvars': {
            'type': 'dict',
            'required': True
        }
    }

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=False
    )

    hostvars = module.params['hostvars']

    k8s_ip_to_node_name_map = {}
    for k, v in hostvars.items():
        if 'k8s_ip' in v.keys():
            k8s_ip_to_node_name_map.update({v['k8s_ip']: k})

    module.exit_json(k8s_ip_to_node_name_map=k8s_ip_to_node_name_map)


if __name__ == '__main__':
    main()
