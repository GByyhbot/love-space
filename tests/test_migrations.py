"""版本化迁移机制的护栏：schema_version 存在、apply_migrations 幂等。"""
from app import db


def test_schema_version_is_at_least_one():
    db.init()  # 幂等；确保基线 schema 已建立
    with db.connect() as c:
        assert int(db.setting(c, 'schema_version', 0)) >= 1


def test_apply_migrations_is_idempotent():
    db.init()
    with db.connect() as c:
        before = int(db.setting(c, 'schema_version', 1))
        assert db.apply_migrations(c) == before
        # 重复执行不应改版本，也不应抛错
        assert db.apply_migrations(c) == before
