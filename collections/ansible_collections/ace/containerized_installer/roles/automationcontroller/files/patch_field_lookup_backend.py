#!/usr/bin/env python3
"""Patch DAB's FieldLookupBackend so `?role_level=` accepts AWX's legacy roles.

The platform UI asks for things like
`/api/controller/v2/organizations/?role_level=notification_admin_role` when it
renders a job or workflow template's detail page. DAB hands that value straight
to `access_ids_qs`, which validates it as a *permission codename*, so every
legacy `*_role` name is rejected and the whole page fails with:

    The permission notification_admin_role is not valid for model organization

AWX already carries the translation for exactly this compatibility layer
(`org_role_to_permission`, `role_name_to_perm_mapping`) and applies it in
`Role.__contains__` -- just not on this filter path. This inserts the same
translation at the one place that needs it.

Reads the original module on stdin, writes the patched module on stdout. Exits
non-zero if either anchor is missing, so an upstream change fails the install
loudly instead of silently mounting an unpatched file.
"""

import sys

HELPER = '''

def _ace_legacy_role_to_codename(model, role_name):
    """Map an AWX legacy role name to a DAB permission codename.

    Returns `role_name` untouched when it is not a legacy name or cannot be
    mapped -- an unmappable filter should still raise, not silently widen
    access to something the caller did not ask for.
    """
    if not isinstance(role_name, str) or not role_name.endswith('_role'):
        return role_name

    try:
        from awx.main.constants import org_role_to_permission, role_name_to_perm_mapping
        from ansible_base.rbac import permission_registry
        from ansible_base.rbac.validators import codenames_for_content_type
    except Exception:
        return role_name

    model_name = model._meta.model_name

    # AWX's own organization map first: it is what Role.__contains__ uses for
    # these same names, so this path agrees with permission evaluation.
    if model_name == 'organization' and role_name in org_role_to_permission:
        return org_role_to_permission[role_name]

    # Otherwise try the prefix map, taking the first prefix that resolves to a
    # permission this model actually has.
    try:
        content_type = permission_registry.content_type_model.objects.get_for_model(model)
        valid_codenames = set(codenames_for_content_type(content_type))
    except Exception:
        return role_name

    for prefix in role_name_to_perm_mapping.get(role_name, []):
        candidate = '{}{}'.format(prefix, model_name)
        if candidate in valid_codenames:
            return candidate

    return role_name

'''

CLASS_ANCHOR = '\n\nclass FieldLookupBackend(BaseFilterBackend):'

CALL_ANCHOR = """                for role_name in role_filters:
                    if hasattr(queryset.model, 'access_ids_qs'):"""

CALL_PATCHED = """                for role_name in role_filters:
                    role_name = _ace_legacy_role_to_codename(queryset.model, role_name)
                    if hasattr(queryset.model, 'access_ids_qs'):"""


def main() -> int:
    source = sys.stdin.read()

    if '_ace_legacy_role_to_codename' in source:
        sys.stdout.write(source)
        return 0

    if CLASS_ANCHOR not in source:
        print('patch_field_lookup_backend: FieldLookupBackend anchor not found', file=sys.stderr)
        return 1
    if CALL_ANCHOR not in source:
        print('patch_field_lookup_backend: role_filters anchor not found', file=sys.stderr)
        return 1

    source = source.replace(CLASS_ANCHOR, HELPER + '\nclass FieldLookupBackend(BaseFilterBackend):', 1)
    source = source.replace(CALL_ANCHOR, CALL_PATCHED, 1)

    sys.stdout.write(source)
    return 0


if __name__ == '__main__':
    sys.exit(main())
