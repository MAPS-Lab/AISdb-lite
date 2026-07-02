''' pass these functions to DBQuery.gen_qry() as the function argument '''
import os

from aisdb import sqlpath

def load_sql(name: str) -> str:
    suffix = '_global'
    path = os.path.join(sqlpath, f'{name}{suffix}.sql')
    with open(path, 'r') as f:
        return f.read()


def _dynamic(*, callback, **kwargs):
    ''' SQL common table expression for selecting from dynamic tables '''
    sql_template = load_sql('cte_dynamic_clusteredidx')
    sql = sql_template.format('global')
    sql += callback(alias='d', **kwargs)
    return sql

def _static(**_):
    """CTE for static tables."""
    sql_template = load_sql('cte_static_aggregate')
    return sql_template.format('global')


def _leftjoin():
    ''' SQL select statement using common table expressions.
        Joins columns from dynamic, static, and coarsetype_ref tables.
    '''
    sql_template = load_sql('select_join_dynamic_static_clusteredidx')
    return sql_template.format('global')


def _aliases(*, callback, kwargs):
    ''' declare common table expression aliases '''
    dyn_sql = _dynamic(callback=callback, **kwargs)
    stat_sql = _static()
    sql_template = load_sql('cte_aliases')
    return sql_template.format(dyn_sql, stat_sql)
   

def crawl_dynamic(*, callback, **kwargs):
    ''' iterate over position reports tables to create SQL query spanning
        desired time range

        this function should be passed as a callback to DBQuery.gen_qry(),
        and should not be called directly
    '''
    sql = _dynamic(callback=callback, **kwargs)
    return sql + '\nORDER BY 1,2'


def crawl_dynamic_static(*, callback, **kwargs):
    ''' iterate over position reports and static messages tables to create SQL
        query spanning desired time range

        this function should be passed as a callback to DBQuery.gen_qry(),
        and should not be called directly
    '''
    sqlfile = 'cte_coarsetype.sql'
    with open(os.path.join(sqlpath, sqlfile), 'r') as f:
        sql_coarsetype = f.read()

    sql_alias = _aliases(callback=callback, kwargs=kwargs)
    sql_union = _leftjoin()
    return f'WITH\n{sql_alias},\n{sql_coarsetype}\n{sql_union}\nORDER BY 1,2'
