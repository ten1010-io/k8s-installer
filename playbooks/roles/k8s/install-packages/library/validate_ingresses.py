from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

from ansible.module_utils.basic import AnsibleModule


def main():
    module_args = {
        'ingresses': {
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

    ingresses = module.params['ingresses']
    node_name_to_k8s_hostname_map = module.params['node_name_to_k8s_hostname_map']

    class_names = set()
    for ingress in ingresses:
        if ingress['ingress_class_name'] in class_names:
            module.fail_json(msg="ingress class name '{}' duplicated".format(ingress['ingress_class_name']))
        class_names.add(ingress['ingress_class_name'])
        for controller_node in ingress['controller_nodes']:
            if controller_node not in node_name_to_k8s_hostname_map.keys():
                module.fail_json(msg="Controller node '{}' does not exist in node_name_to_k8s_hostname_map.keys()".format(controller_node))
    module.exit_json()


if __name__ == '__main__':
    main()
