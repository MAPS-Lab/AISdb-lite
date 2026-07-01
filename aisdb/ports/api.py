import requests


class WorldPortIndexClient:
    """
    A client to query the World Port Index (WPI) FeatureServer
    and extract port data by bounding box or other filters.
    """

    def __init__(self, timeout=60):
        self.base_url = (
            "https://services9.arcgis.com/j1CY4yzWfwptbTWN/"
            "arcgis/rest/services/WorldPortIndex_WFL1/FeatureServer/0/query"
        )
        self.timeout = timeout

    def _build_where_clause(self, lat_min, lat_max, lon_min, lon_max):
        bounds = {
            "lat_min": lat_min,
            "lat_max": lat_max,
            "lon_min": lon_min,
            "lon_max": lon_max,
        }
        for name, value in bounds.items():
            if not isinstance(value, (int, float)):
                raise TypeError(f"{name} must be numeric, got {type(value).__name__}")
        if not (-90 <= lat_min <= lat_max <= 90):
            raise ValueError(f"invalid latitude range: {lat_min}..{lat_max}")
        if not (-180 <= lon_min <= lon_max <= 180):
            raise ValueError(f"invalid longitude range: {lon_min}..{lon_max}")
        return (
            f"LATITUDE >= {lat_min} AND LATITUDE <= {lat_max} AND "
            f"LONGITUDE >= {lon_min} AND LONGITUDE <= {lon_max}"
        )

    def fetch_ports(
        self, lat_min, lat_max, lon_min, lon_max, save=False, out_path=None
    ):
        """
        Fetches ports within the given bounding box.

        Parameters:
            lat_min, lat_max: float
            lon_min, lon_max: float
            save: bool, whether to save to CSV
            out_path: optional, required if save=True

        Returns:
            pd.DataFrame of port records
        """
        # Lazy import: pandas is only needed by the ports API, and importing it
        # here keeps `import aisdb` light.
        import pandas as pd

        where = self._build_where_clause(lat_min, lat_max, lon_min, lon_max)
        params = {"where": where, "outFields": "*", "f": "geojson"}

        print(f"Querying WPI with bounds: {where}")
        response = requests.get(self.base_url, params=params, timeout=self.timeout)
        response.raise_for_status()
        geojson = response.json()

        features = geojson.get("features", [])
        records = [
            {
                **f["properties"],
                "LAT": f["geometry"]["coordinates"][1],
                "LON": f["geometry"]["coordinates"][0],
            }
            for f in features
        ]

        df = pd.DataFrame(records)
        print(f"Retrieved {len(df)} ports")

        if save:
            if not out_path:
                raise ValueError("You must specify out_path when save=True")
            df.to_csv(out_path, index=False)
            print(f"Saved to {out_path}")

        return df

    def filter_by_cargo_depth(self, df, valid_depths=("A", "B", "C", "D", "E", "F")):
        """
        Filters DataFrame to only include ports with valid cargo depth codes.

        Parameters:
            df: DataFrame
            valid_depths: Tuple of allowed CARGODEPTH codes

        Returns:
            Filtered DataFrame
        """
        filtered = df[df["CARGODEPTH"].isin(valid_depths)]
        print(f"{len(filtered)} ports with cargo depth in {valid_depths}")
        return filtered
