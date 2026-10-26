from services.audit import audit_summary


def rename_user(user, name):
    user["name"] = name
    return audit_summary()
