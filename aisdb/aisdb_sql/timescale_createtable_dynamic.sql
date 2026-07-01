CREATE TABLE IF NOT EXISTS ais_global_dynamic
(
    mmsi          BIGINT NOT NULL,
    time          BIGINT NOT NULL,
    longitude     REAL NOT NULL,
    latitude      REAL NOT NULL,
    rot           REAL,
    sog           REAL,
    cog           REAL,
    heading       REAL,
    maneuver      BOOLEAN,
    utc_second    INTEGER,
    source        TEXT NOT NULL,
    geom          GEOMETRY(POINT, 4326)
                  GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)) STORED,
    PRIMARY KEY (mmsi, time, latitude, longitude)
);

SELECT create_hypertable(
    'ais_global_dynamic',
    'time',
    partitioning_column => 'mmsi',
    number_partitions => 4,
    chunk_time_interval => 604800,
    if_not_exists => TRUE,
    migrate_data => TRUE
);

-- When a plain (non-timescale) table was migrated into a hypertable above,
-- it lacks the generated geom column; add it before building the GiST index.
ALTER TABLE ais_global_dynamic
    ADD COLUMN IF NOT EXISTS geom GEOMETRY(POINT, 4326)
    GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)) STORED;

ALTER TABLE ais_global_dynamic SET (
    timescaledb.compress = false,
    timescaledb.compress_orderby = 'time ASC, latitude ASC, longitude ASC',
    timescaledb.compress_segmentby = 'mmsi'
);

CREATE INDEX IF NOT EXISTS idx_ais_global_dynamic_geom ON ais_global_dynamic USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_ais_global_dynamic_time ON ais_global_dynamic USING BRIN (time);