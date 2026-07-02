import os

from aisdb import sqlpath

with open(os.path.join(sqlpath, "createtable_static_global_aggregate.sql"), "r") as f:
    sql_global_aggregate = f.read()
