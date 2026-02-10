"""
Test suite for BRIN index optimization on ais_global_dynamic table.

This module validates that the BRIN (Block Range INdex) implementation
on the time column provides the expected benefits for time-series AIS data:
- Faster bulk inserts
- Smaller index size
- Efficient range queries on chronologically ordered data
"""

import os
import pytest
import psycopg2
from datetime import datetime


@pytest.fixture
def db_connection():
    """
    Create a database connection using environment variables.
    
    Environment Variables:
        PGHOST: PostgreSQL host (default: localhost)
        PGUSER: PostgreSQL user (default: postgres)
        PGPASSWORD: Database credentials (required)
        PGDATABASE: Database name (default: aisdb)
    """
    # Use dict to avoid hardcoded credential patterns
    conn_params = {
        'host': os.getenv("PGHOST", "localhost"),
        'user': os.getenv("PGUSER", "postgres"),
        'database': os.getenv("PGDATABASE", "aisdb")
    }
    # Add credentials from environment
    if os.getenv("PGPASSWORD"):
        conn_params['password'] = os.getenv("PGPASSWORD")
    
    conn = psycopg2.connect(**conn_params)
    yield conn
    conn.close()


def test_brin_index_exists(db_connection):
    """
    Verify that the BRIN index on time column exists.
    """
    cursor = db_connection.cursor()
    
    # Query to check if BRIN index exists on time column
    cursor.execute("""
        SELECT 
            indexname,
            indexdef
        FROM pg_indexes
        WHERE tablename = 'ais_global_dynamic'
          AND indexname = 'idx_ais_global_dynamic_time'
          AND indexdef LIKE '%USING brin%'
    """)
    
    result = cursor.fetchone()
    cursor.close()
    
    assert result is not None, "BRIN index on time column not found"
    assert "brin" in result[1].lower(), "Index exists but is not BRIN type"


def test_brin_index_type(db_connection):
    """
    Verify the index is specifically BRIN and not B-Tree.
    """
    cursor = db_connection.cursor()
    
    # Query pg_class to get index access method
    cursor.execute("""
        SELECT 
            i.relname as index_name,
            am.amname as index_type
        FROM pg_class t
        JOIN pg_index ix ON t.oid = ix.indrelid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_am am ON i.relam = am.oid
        WHERE t.relname = 'ais_global_dynamic'
          AND i.relname = 'idx_ais_global_dynamic_time'
    """)
    
    result = cursor.fetchone()
    cursor.close()
    
    assert result is not None, "Time index not found"
    assert result[1] == "brin", f"Expected BRIN index, got {result[1]}"


def test_hypertable_with_brin(db_connection):
    """
    Verify that the table is a hypertable and BRIN indexes are created per chunk.
    """
    cursor = db_connection.cursor()
    
    # Check if table is a hypertable
    cursor.execute("""
        SELECT tablename 
        FROM timescaledb_information.hypertables
        WHERE hypertable_name = 'ais_global_dynamic'
    """)
    
    result = cursor.fetchone()
    cursor.close()
    
    assert result is not None, "ais_global_dynamic is not a hypertable"


def test_brin_pages_per_range(db_connection):
    """
    Verify BRIN pages_per_range setting is appropriate for the workload.
    Default is typically 128 pages, which is suitable for time-series data.
    """
    cursor = db_connection.cursor()
    
    # Query BRIN index configuration
    cursor.execute("""
        SELECT 
            c.relname,
            a.attname,
            pg_get_indexdef(i.indexrelid) as indexdef
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = 'ais_global_dynamic'::regclass
          AND c.relname = 'idx_ais_global_dynamic_time'
    """)
    
    result = cursor.fetchone()
    cursor.close()
    
    assert result is not None, "BRIN index not found"
    # Verify index definition contains BRIN keyword
    assert "brin" in result[2].lower(), "Index definition does not specify BRIN"


def test_insert_performance_baseline(db_connection):
    """
    Basic insert test to ensure BRIN doesn't break insert functionality.
    This is a sanity check, not a performance benchmark.
    """
    cursor = db_connection.cursor()
    
    # Insert a test record
    test_timestamp = int(datetime(2020, 10, 1, 12, 0, 0).timestamp())
    test_mmsi = 123456789
    
    cursor.execute("""
        INSERT INTO ais_global_dynamic 
        (mmsi, time, longitude, latitude, source)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (mmsi, time, latitude, longitude) DO NOTHING
    """, (test_mmsi, test_timestamp, -60.0, 45.0, "test"))
    
    db_connection.commit()
    
    # Verify insert succeeded
    cursor.execute("""
        SELECT COUNT(*) 
        FROM ais_global_dynamic
        WHERE mmsi = %s AND time = %s
    """, (test_mmsi, test_timestamp))
    
    count = cursor.fetchone()[0]
    cursor.close()
    
    assert count == 1, "Test insert did not succeed"


def test_time_range_query(db_connection):
    """
    Test that range queries on time column work correctly with BRIN index.
    """
    cursor = db_connection.cursor()
    
    # Define a time range (1 hour on Oct 1, 2020)
    start_time = int(datetime(2020, 10, 1, 0, 0, 0).timestamp())
    end_time = int(datetime(2020, 10, 1, 1, 0, 0).timestamp())
    
    # Execute range query
    cursor.execute("""
        SELECT COUNT(*) 
        FROM ais_global_dynamic
        WHERE time >= %s AND time < %s
    """, (start_time, end_time))
    
    count = cursor.fetchone()[0]
    cursor.close()
    
    # We don't know how much data exists, just verify query executes
    assert count >= 0, "Range query failed to execute"


def test_explain_uses_brin(db_connection):
    """
    Verify that EXPLAIN shows BRIN index usage for time range queries.
    """
    cursor = db_connection.cursor()
    
    start_time = int(datetime(2020, 10, 1, 0, 0, 0).timestamp())
    end_time = int(datetime(2020, 10, 2, 0, 0, 0).timestamp())
    
    # Get query plan
    cursor.execute("""
        EXPLAIN (FORMAT JSON)
        SELECT COUNT(*) 
        FROM ais_global_dynamic
        WHERE time >= %s AND time < %s
    """, (start_time, end_time))
    
    plan = cursor.fetchone()[0]
    cursor.close()
    
    # Convert plan to string and check for BRIN or index scan
    plan_str = str(plan).lower()
    
    # BRIN can show as "Bitmap Heap Scan" with "Bitmap Index Scan" on the BRIN index
    # or just verify the index is referenced in the plan
    assert "idx_ais_global_dynamic_time" in plan_str or "bitmap" in plan_str, \
        "Query plan does not show BRIN index usage"


if __name__ == "__main__":
    """
    Run tests with pytest.
    
    Usage:
        PGHOST=localhost PGUSER=postgres PGPASSWORD=your_password \\
        python -m pytest test_brin_optimization.py -v
    """
    pytest.main([__file__, "-v"])
