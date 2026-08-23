#!/usr/bin/env python3
"""Seed a LOCAL ClickHouse with Fivetran-shaped raw data for the organic platforms.

WHY THIS EXISTS
---------------
`frnd-orchestration` is the middle of a three-layer pipeline, so it cannot be
exercised without a raw layer. The local demo cluster ships *placeholder* raw
tables — every `raw_ig_*.media_insights` locally has five columns
(`id, name, value, _fivetran_synced, _fivetran_deleted`), not Meta's real
per-type metric table — so the transforms have nothing to read and every metric
downstream renders as an em dash. That is not a bug in the pipeline; it is an
absent source.

This script builds that source: real table shapes, plausible rows, one sandbox
brand, entirely on localhost.

    raw_<alias>_<brand>  ->  transform flow  ->  staging_<workspace>
                         ->  load_marts      ->  frnd_agg_marts.*

WHERE THE SCHEMA COMES FROM
---------------------------
`orchestration/config_handover/*.yaml` — the Fivetran allow-list, which is the
contract each transformer reads against. Deriving the columns from those files
rather than hand-writing them means the fixture cannot drift from the pipeline's
own expectations: add a column to the allow-list and the fixture grows with it.

Types are inferred by name (see `_ch_type`), with explicit overrides for the
columns where the guess would be wrong or where the VALUE carries meaning —
`reels_skip_rate` is a 0-100 percentage, the `ig_reels_*` pair is milliseconds.

SAFETY
------
Refuses to run against anything but localhost. Every statement is scoped to
`raw_<alias>_<brand_id>` databases for the brand you pass; it never touches
`frnd_agg_marts`, `staging_*`, or any pre-existing raw database unless that
database name matches the brand you named.

    python3 scripts/local-seed-raw.py --list
    python3 scripts/local-seed-raw.py --brand <ulid> --platforms ig
    python3 scripts/local-seed-raw.py --brand <ulid> --posts 40 --drop
"""
from __future__ import annotations

import argparse
import random
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ORCH = REPO / "orchestration"

# Organic platforms only. Paid (`*_ads`) and the Google-Sheet sources have very
# different shapes and are not what the owned-media marts read.
PLATFORMS = {
    "ig": ("instagram_business", "instagram_business.yaml"),
    "fb": ("facebook_pages", "facebook_pages.yaml"),
    "tt": ("tiktok", "tiktok.yaml"),
    "yt": ("youtube", "youtube.yaml"),
}

# Fivetran injects these at the destination regardless of the allow-list, and the
# transforms depend on both: `_fivetran_synced` is the argMax tiebreaker for SCD2
# dedup, `_fivetran_deleted` is the soft-delete flag the staging helpers filter on.
FIVETRAN_META = {
    "_fivetran_synced": "DateTime",
    "_fivetran_deleted": "Nullable(UInt8)",
    # Auto-injected at the destination and never configurable in the allow-list
    # (the YAMLs say so explicitly), which makes it easy to forget in a fixture.
    # `flows/facebook_pages/transform_flow.py` depends on it: Facebook comment
    # `id` is NULLABLE at source, so `_fivetran_id` is the stable comment key
    # the sentiments and word-cloud marts join on.
    "_fivetran_id": "String",
}

# Columns whose type or meaning the name-based guess would get wrong.
TYPE_OVERRIDES = {
    # 0-100 percentage, Nullable because Meta withholds it on ~2/3 of reels.
    "reels_skip_rate": "Nullable(Float64)",
    # MILLISECONDS. Nullable: reels-only, and absent is not zero.
    "ig_reels_avg_watch_time": "Nullable(Float64)",
    "ig_reels_video_view_total_time": "Nullable(Float64)",
    # EAV payloads — `value` is a count, `key`/`metric` are strings.
    "value": "Nullable(Int64)",
    "percentage": "Nullable(Float64)",
    "views_percentage": "Nullable(Float64)",
    # YouTube ISO-8601 duration ("PT1M30S"), parsed by the transform.
    "content_details_duration": "String",
    "age_gender": "String",
    "age_group": "String",
}

STRINGISH = (
    "id", "name", "username", "title", "description", "caption", "text", "url",
    "permalink", "type", "key", "metric", "message", "status", "category",
    "custom_url", "embed_url", "share_url", "thumbnail", "media_url",
    # Geography, and the reason it is here: the Facebook region query does
    # `splitByString(', ', city)` on `daily_page_metrics_by_city.city`. Typed as
    # a number — which is what the heuristic guessed before "city" was listed —
    # the flow dies with "illegal type ... as 2nd argument to splitByString".
    "city", "country", "region", "province", "age", "gender", "age_group",
)
DATEISH = ("date", "time", "created", "updated", "published", "timestamp")


def _ch_type(col: str) -> str:
    """Best-guess ClickHouse type for a raw column, by name.

    Deliberately biased toward Nullable numerics: that is what Fivetran actually
    lands, and it is the shape that exercises the transforms' coalesce/argMax
    handling rather than papering over it with non-null defaults.
    """
    if col in TYPE_OVERRIDES:
        return TYPE_OVERRIDES[col]
    if col in FIVETRAN_META:
        return FIVETRAN_META[col]
    low = col.lower()
    if any(low == s or low.endswith("_" + s) or s in low for s in DATEISH):
        return "DateTime"
    if any(low == s or low.endswith("_" + s) or low.startswith(s) for s in STRINGISH):
        return "String"
    if "rate" in low or "percentage" in low or "average" in low:
        return "Nullable(Float64)"
    return "Nullable(Int64)"


# Columns a transform reads that the allow-list does NOT name. This is real
# drift, not a bug in this script: `flows/instagram_business/transform_flow.py`
# argMax's 24 columns out of `media_insights`, and `instagram_business.yaml`
# enables 24 columns of which several are a different set — the shares/saved/
# like/comment family is read but never allow-listed. Seeding only the
# allow-list would fail the transform with NO_SUCH_COLUMN_IN_TABLE.
#
# Regenerate with:
#   grep -oE 'argMax\(\s*[a-z_0-9]+' flows/<platform>/transform_flow.py
REQUIRED_COLUMNS = {
    # Facebook: `post_history.share_count` is read by the content query and is
    # absent from `facebook_pages.yaml`.
    ("fb", "post_history"): ["share_count"],
    # TikTok is the worst case in the repo: the allow-list and the transform
    # disagree on the NAMES of most video metrics. `tiktok.yaml` enables
    # `view_count` / `like_count` / `comment_count` / `share_count` /
    # `video_description` / `cover_image_url`; `flows/tiktok/transform_flow.py`
    # reads `video_views` / `likes` / `comments` / `shares` / `caption` /
    # `thumbnail_url`, plus `favorites` and `reach`, which the YAML never
    # mentions at all. Both sets are seeded so the fixture satisfies the code
    # while still matching the documented contract.
    ("tt", "video"): [
        "caption", "comments", "favorites", "likes", "reach", "shares",
        "thumbnail_url", "video_views",
    ],
    ("tt", "profile_metric"): ["unique_video_views"],
    ("tt", "profile_audience_age"): ["age"],
    # `reel_history.embed_html` is read by the creative-assets uploader, which
    # scrapes a cover image out of the embed markup because FB reels carry no
    # image column. Absent from the allow-list; without it the uploader task
    # fails the whole flow run even though the marts already loaded.
    ("fb", "reel_history"): ["embed_html"],
    ("ig", "media_insights"): [
        "video_photo_shares", "video_photo_saved",
        "reel_shares", "reel_saved",
        "story_replies", "story_shares",
        "carousel_album_shares", "carousel_album_saved",
        "like_count", "comment_count",
    ],
}


def load_contract(yaml_path: Path) -> dict[str, list[str]]:
    """{destination_table: [columns]} from one Fivetran allow-list file.

    Keyed by `name_in_destination` where the file sets one. That distinction is
    load-bearing for YouTube: the YAML keys are `channel_basic_a2` /
    `channel_demographics_a1`, while the tables Fivetran actually lands — and
    the ones `flows/youtube/transform_flow.py` reads — are `channel_basic_a_2`
    and `channel_demographics_a_1`. Keying by the YAML key would build two
    tables no flow will ever open.
    """
    import yaml  # from the orchestration venv

    doc = yaml.safe_load(yaml_path.read_text())
    out: dict[str, list[str]] = {}
    for _db, spec in (doc.get("schemas") or {}).items():
        for table, tspec in (spec.get("tables") or {}).items():
            tspec = tspec or {}
            cols = list((tspec.get("columns") or {}).keys())
            if cols:
                out[tspec.get("name_in_destination") or table] = cols
    return out


# ---------------------------------------------------------------------------
# Row generation
# ---------------------------------------------------------------------------

def _base_value(col: str, ch_type: str, rng: random.Random, i: int, when: datetime):
    if ch_type.startswith("DateTime"):
        return when
    if "String" in ch_type:
        return f"{col}-{i}"
    if "Float64" in ch_type:
        return round(rng.uniform(1, 100), 2)
    return rng.randint(0, 5000)


class Seeder:
    """Builds one brand's raw layer, one platform at a time."""

    def __init__(self, ch, brand: str, posts: int, seed: int, verbose: bool = True):
        self.ch = ch
        self.brand = brand
        self.posts = posts
        self.rng = random.Random(seed)
        self.verbose = verbose
        self.base = datetime(2026, 8, 1, 9, 0, 0)  # after STAGING_DATE_CUTOFF (2026-01-01)

    def log(self, msg: str) -> None:
        if self.verbose:
            print(msg)

    # Registry platform labels are inconsistently cased in local data
    # ('TikTok' alongside 'tiktok'), so the lookup below matches case-insensitively.
    _REGISTRY_PLATFORM = {
        "ig": "instagram", "fb": "facebook", "tt": "tiktok", "yt": "youtube",
    }

    def registered_account(self, alias: str) -> str | None:
        """The account id this brand already has registered, if any.

        Reusing it matters: `load_marts` LEFT JOINs `frnd_os_master.
        account_ownership` on account_id to resolve `account_name`. Invent a
        fresh id and the join misses, every mart row lands with an empty
        account name, and the dashboard's account filter cannot resolve the
        rows — the exact bug `_account_name_source` exists to prevent.
        """
        want = self._REGISTRY_PLATFORM[alias]
        rows = self.ch.query(
            "SELECT account_id FROM frnd_os_master.account_ownership "
            "WHERE brand_id = {b:String} AND lower(platform) = {p:String} "
            "AND deleted_at IS NULL ORDER BY account_index LIMIT 1",
            parameters={"b": self.brand, "p": want},
        ).result_rows
        return rows[0][0] if rows else None

    @staticmethod
    def _type_from_sample(rows: list[dict], col: str) -> str | None:
        """Type a column from the value a builder actually produced.

        The name heuristic gets most columns right and some spectacularly wrong
        — `full_picture` holds a URL and guesses Int64, because no substring in
        it reads as text. A value that exists is better evidence than its name,
        so it wins; the heuristic only covers columns nobody set.
        """
        for r in rows:
            v = r.get(col)
            if v is None:
                continue
            if isinstance(v, datetime):
                return "DateTime"
            if isinstance(v, bool):
                return "Nullable(UInt8)"
            if isinstance(v, str):
                return "String"
            if isinstance(v, float):
                return "Nullable(Float64)"
            if isinstance(v, int):
                return "Nullable(Int64)"
        return None

    def create_table(self, db: str, table: str, cols: list[str],
                     rows: list[dict] | None = None) -> list[tuple[str, str]]:
        rows = rows or []
        typed = [(c, self._type_from_sample(rows, c) or _ch_type(c)) for c in cols]
        for meta, mtype in FIVETRAN_META.items():
            if meta not in cols:
                typed.append((meta, mtype))
        defs = ", ".join(f"`{c}` {t}" for c, t in typed)
        # ORDER BY the first column (always an id in these contracts) so SCD2
        # snapshots for one entity sit together, mirroring the destination.
        self.ch.command(
            f"CREATE TABLE IF NOT EXISTS `{db}`.`{table}` ({defs}) "
            f"ENGINE = MergeTree ORDER BY tuple()"
        )
        return typed

    def insert(self, db: str, table: str, typed: list[tuple[str, str]], rows: list[dict]) -> int:
        """Insert rows, filling any contract column the builder left unset.

        The row builders only set the columns that carry MEANING — foreign keys,
        dates, and the metrics under test. Everything else in the allow-list
        still has to be populated, because a non-Nullable String (Facebook's
        `status_type`, for one) rejects a None outright. Filling generically
        also keeps the fixture honest: a column nobody set still exists and
        still holds a value, exactly as it would coming off Fivetran.
        """
        if not rows:
            return 0
        names = [c for c, _ in typed]
        types = dict(typed)
        for i, r in enumerate(rows):
            when = next(
                (v for v in r.values() if isinstance(v, datetime)), self.base
            )
            for c in names:
                if r.get(c) is None and c not in r:
                    r[c] = (
                        0 if c == "_fivetran_deleted"
                        else _base_value(c, types[c], self.rng, i, when)
                    )
        data = [[r.get(c) for c in names] for r in rows]
        self.ch.insert(table, data, column_names=names, database=db)
        return len(rows)

    # -- per-platform row builders -----------------------------------------
    #
    # Each returns {table: [row dicts]}. Only the columns that carry MEANING are
    # set explicitly — foreign keys, dates, and the metrics under test. Every
    # other column in the contract is filled generically, which is fine: the
    # transforms either ignore it or pass it through.

    def rows_ig(self, contract):
        acct = self.registered_account("ig") or f"ig-acct-{self.brand[:8]}"
        media, insights, comments = [], [], []
        for i in range(self.posts):
            when = self.base + timedelta(days=i % 28, hours=i % 7)
            mid = f"ig-media-{i:04d}"
            # A third of posts are reels — the only IG media type Meta reports
            # watch time and skip rate for.
            is_reel = i % 3 == 0
            product = "REELS" if is_reel else ("STORY" if i % 7 == 0 else "FEED")
            mtype = "VIDEO" if is_reel else ("CAROUSEL_ALBUM" if i % 5 == 0 else "IMAGE")
            media.append({
                "id": mid, "user_id": acct, "created_time": when,
                "media_type": mtype, "media_product_type": product,
                "permalink": f"https://instagram.com/p/{mid}",
                "caption": f"Local fixture post {i} #frndos #localdev",
                "thumbnail_url": f"https://cdn.example/{mid}.jpg",
                "media_url": f"https://cdn.example/{mid}-full.jpg",
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })

            reel_views = self.rng.randint(2_000, 120_000) if is_reel else None
            row = {"id": mid, "_fivetran_synced": when, "_fivetran_deleted": 0}

            # PRE-SET EVERY PER-TYPE METRIC TO NULL, then fill only the family
            # that matches this post's media type. This is not tidiness — it is
            # the difference between a fixture that behaves like Meta and one
            # that does not.
            #
            # The transform projects `video_views` as
            # `coalesce(video_photo_views, reel_views, story_views, …)`, which
            # is only correct because Meta populates exactly ONE family per
            # post. Leave these keys absent and the generic filler supplies a
            # value for all of them, so the coalesce picks `video_photo_views`
            # on a REEL — while `retained_views_3s` is still derived from
            # `reel_views`. Measured on the first seeded run: 6 of 14 reels came
            # out with retained_views_3s > video_views, violating the invariant
            # migration v2/022 documents. The pipeline was right; the fixture
            # was lying to it.
            #
            # `*_follows` / `*_reposts` are deliberately NOT in this list: Meta
            # really does duplicate those across the type-prefixed columns.
            for fam, metrics in (
                ("video_photo", ("views", "reach", "impressions", "engagement", "shares", "saved")),
                ("reel", ("views", "reach", "total_interactions", "shares", "saved")),
                ("story", ("views", "reach", "impressions", "replies", "shares")),
                ("carousel_album", ("views", "reach", "impressions", "engagement", "shares", "saved")),
            ):
                for m in metrics:
                    row[f"{fam}_{m}"] = None
            # Reels-only signals. NULL on every other media type, because a feed
            # post has no watch time and no skip concept at all.
            row["ig_reels_avg_watch_time"] = None
            row["ig_reels_video_view_total_time"] = None
            row["reels_skip_rate"] = None

            if is_reel:
                row.update({
                    "reel_views": reel_views,
                    "reel_reach": int(reel_views * 0.82),
                    "reel_total_interactions": self.rng.randint(50, 4_000),
                    "reel_shares": self.rng.randint(0, 400),
                    "reel_saved": self.rng.randint(0, 900),
                    # MILLISECONDS. avg is a per-viewer MEAN; total is the
                    # additive companion. total/avg reconstructs a view count,
                    # which is how the unit was established upstream (r=0.997).
                    "ig_reels_avg_watch_time": float(self.rng.randint(3_000, 14_000)),
                })
                row["ig_reels_video_view_total_time"] = float(
                    row["ig_reels_avg_watch_time"] * reel_views
                )
                # Three populations, on purpose:
                #   ~25% NULL   — Meta never returned the metric
                #   ~15% 0      — Meta returned a zero it did not measure; the
                #                 transform maps this to NULL via nullIf
                #   rest 1-87   — a real measurement
                draw = self.rng.random()
                if draw < 0.25:
                    row["reels_skip_rate"] = None
                elif draw < 0.40:
                    row["reels_skip_rate"] = 0.0
                else:
                    row["reels_skip_rate"] = round(self.rng.uniform(1, 87), 2)
            elif product == "STORY":
                row.update({
                    "story_views": self.rng.randint(500, 9_000),
                    "story_reach": self.rng.randint(400, 8_000),
                    "story_impressions": self.rng.randint(500, 9_500),
                    "story_replies": self.rng.randint(0, 60),
                    "story_shares": self.rng.randint(0, 90),
                })
            elif mtype == "CAROUSEL_ALBUM":
                row.update({
                    "carousel_album_views": self.rng.randint(1_000, 40_000),
                    "carousel_album_reach": self.rng.randint(900, 35_000),
                    "carousel_album_impressions": self.rng.randint(1_000, 45_000),
                    "carousel_album_engagement": self.rng.randint(40, 2_500),
                    "carousel_album_shares": self.rng.randint(0, 300),
                    "carousel_album_saved": self.rng.randint(0, 800),
                })
            else:
                row.update({
                    "video_photo_views": self.rng.randint(1_000, 60_000),
                    "video_photo_reach": self.rng.randint(900, 50_000),
                    "video_photo_impressions": self.rng.randint(1_000, 65_000),
                    "video_photo_engagement": self.rng.randint(40, 3_000),
                    "video_photo_shares": self.rng.randint(0, 350),
                    "video_photo_saved": self.rng.randint(0, 1_200),
                })

            # Follows and reposts. Meta DUPLICATES these across the type-prefixed
            # columns rather than scoping them per media type, so the fixture
            # duplicates them too — otherwise the transform's coalesce would be
            # tested against a shape the real source never produces.
            follows = self.rng.randint(0, 120)
            reposts = self.rng.randint(0, 60)
            row.update({
                "video_photo_follows": follows, "carousel_album_follows": follows,
                "story_follows": 0,
                "video_photo_reposts": reposts, "carousel_album_reposts": reposts,
                "reel_reposts": reposts,
                "like_count": self.rng.randint(10, 5_000),
                "comment_count": self.rng.randint(0, 400),
            })
            insights.append(row)

            for c in range(self.rng.randint(0, 3)):
                comments.append({
                    "id": f"{mid}-c{c}", "media_id": mid, "created_time": when,
                    "owner_username": f"viewer_{self.rng.randint(1, 400)}",
                    "text": self.rng.choice([
                        "love this so much", "when is the restock?",
                        "not for me honestly", "the quality is unreal",
                    ]),
                    "_fivetran_synced": when, "_fivetran_deleted": 0,
                })

        user_hist = [{
            "id": acct, "name": "FRND Local Sandbox", "username": "frnd_local",
            "followers_count": 148_000,
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        }]
        user_ins = [{
            "id": acct, "date": self.base + timedelta(days=d),
            # DAILY DELTAS, not cumulative — the transform back-calculates
            # history as current_total - SUM(net_change after date).
            "follower_count": self.rng.randint(50, 900),
            "unfollower_count": self.rng.randint(10, 300),
            "views": self.rng.randint(5_000, 60_000),
            "reach": self.rng.randint(4_000, 50_000),
            "_fivetran_synced": self.base + timedelta(days=d), "_fivetran_deleted": 0,
        } for d in range(28)]

        # EAV, exactly as Meta encodes it.
        life = []
        for d in (0, 14, 27):
            when = self.base + timedelta(days=d)
            for g in ("M", "F"):
                for band in ("18-24", "25-34", "35-44", "45-54"):
                    life.append({
                        "id": acct, "date": when, "metric": "audience_gender_age",
                        "key": f"{g}.{band}", "value": self.rng.randint(200, 9_000),
                        "_fivetran_synced": when, "_fivetran_deleted": 0,
                    })
            for city in ("Jakarta, Jakarta", "Bandung, West Java", "Surabaya, East Java"):
                life.append({
                    "id": acct, "date": when, "metric": "audience_city",
                    "key": city, "value": self.rng.randint(500, 20_000),
                    "_fivetran_synced": when, "_fivetran_deleted": 0,
                })
            life.append({
                "id": acct, "date": when, "metric": "audience_country",
                "key": "ID", "value": self.rng.randint(50_000, 140_000),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })

        return {
            "user_history": user_hist, "media_history": media,
            "media_insights": insights, "user_insights": user_ins,
            "user_lifetime_insights": life, "media_comment": comments,
        }

    def rows_fb(self, contract):
        page = self.registered_account("fb") or f"fb-page-{self.brand[:8]}"
        posts, post_metrics, reels, reel_metrics, comments, age_gender = [], [], [], [], [], []
        for i in range(self.posts):
            when = self.base + timedelta(days=i % 28, hours=i % 5)
            pid = f"fb-post-{i:04d}"
            posts.append({
                "id": pid, "page_id": page, "created_time": when,
                "message": f"Facebook fixture post {i}",
                "permalink_url": f"https://facebook.com/{pid}",
                "full_picture": f"https://cdn.example/{pid}.jpg",
                "share_count": self.rng.randint(0, 800),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            views = self.rng.randint(1_000, 90_000)
            post_metrics.append({
                "post_id": pid, "date": when,
                # Meta's measured >=3-second count. This is the metric the mart
                # calls `video_views`, and the reason Facebook needs no estimate.
                "post_video_views": int(views * 0.55),
                "post_media_view": views,
                # MILLISECONDS despite the mart column being named for seconds
                # (ledger N5) — the fixture reproduces the defect rather than
                # hiding it, so anything that divides by it fails here first.
                "post_video_length": self.rng.randint(8_000, 90_000),
                "post_clicks": self.rng.randint(10, 4_000),
                "post_reactions_like_total": self.rng.randint(10, 4_000),
                "post_reactions_love_total": self.rng.randint(0, 900),
                "post_reactions_wow_total": self.rng.randint(0, 200),
                "post_reactions_haha_total": self.rng.randint(0, 300),
                "post_reactions_sorry_total": self.rng.randint(0, 60),
                "post_reactions_anger_total": self.rng.randint(0, 40),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            age_gender.append({
                "post_id": pid, "date": when, "age_gender": "F.25-34",
                "post_video_view_time_by_age_bucket_and_gender": self.rng.randint(1_000, 90_000),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            for c in range(self.rng.randint(0, 2)):
                comments.append({
                    "id": f"{pid}-c{c}", "post_id": pid, "created_time": when,
                    "message": "great post", "from_name": f"user{c}",
                    "_fivetran_synced": when, "_fivetran_deleted": 0,
                })

        for i in range(max(4, self.posts // 4)):
            when = self.base + timedelta(days=i % 28)
            rid = f"fb-reel-{i:04d}"
            reels.append({
                "id": rid, "page_id": page, "created_time": when,
                "title": f"Reel {i}", "description": f"Facebook reel fixture {i}",
                "length": self.rng.randint(10, 90),
                "permalink_url": f"https://facebook.com/reel/{rid}",
                "views": self.rng.randint(3_000, 150_000),
                "updated_time": when,
                # Shaped like the real thing so the scraper's regex has
                # something to match rather than erroring on an empty string.
                "embed_html": (
                    f'<iframe src="https://www.facebook.com/plugins/video.php'
                    f'?href=https%3A%2F%2Fweb.facebook.com%2Freel%2F{rid}"></iframe>'
                ),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            reel_metrics.append({
                "reel_id": rid, "date": when,
                "blue_reels_play_count": self.rng.randint(2_000, 140_000),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })

        pages = [{
            "id": page, "name": "FRND Local Page", "username": "frndlocal",
            "followers_count": 96_000, "fan_count": 96_000,
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        }]
        daily = [{
            "page_id": page, "date": self.base + timedelta(days=d),
            "page_follows": 96_000 + d * 40,
            "page_impressions": self.rng.randint(20_000, 90_000),
            "_fivetran_synced": self.base + timedelta(days=d), "_fivetran_deleted": 0,
        } for d in range(28)]
        uniq = [{
            "page_id": page, "date": self.base + timedelta(days=d),
            "page_video_views_unique": self.rng.randint(3_000, 30_000),
            "page_daily_follows_unique": self.rng.randint(20, 400),
            "page_daily_unfollows_unique": self.rng.randint(5, 120),
            "_fivetran_synced": self.base + timedelta(days=d), "_fivetran_deleted": 0,
        } for d in range(28)]

        # Facebook encodes city as "<City>, <Province>" and the region query
        # splits on ", " — so the separator has to be present in the fixture or
        # every row would fall through to the `Lainnya` bucket.
        by_city = [{
            "page_id": page, "date": self.base + timedelta(days=d),
            "city": city, "page_follows_city": self.rng.randint(200, 9_000),
            "_fivetran_synced": self.base + timedelta(days=d), "_fivetran_deleted": 0,
        } for d in range(7)
          for city in ("Jakarta, Jakarta", "Bandung, West Java", "Medan, North Sumatra")]

        return {
            "daily_page_metrics_by_city": by_city,
            "page": pages, "post_history": posts,
            "lifetime_post_metrics_total": post_metrics,
            "lifetime_post_metrics_by_age_gender": age_gender,
            "reel_history": reels, "lifetime_reel_metrics_total": reel_metrics,
            "post_comment_history": comments,
            "daily_page_metrics_total": daily,
            "unique_daily_page_metrics_total": uniq,
        }

    def rows_tt(self, contract):
        user = self.registered_account("tt") or "frnd_local_tt"
        videos, comments = [], []
        for i in range(self.posts):
            when = self.base + timedelta(days=i % 28, hours=i % 4)
            vid = f"tt-video-{i:04d}"
            views = self.rng.randint(5_000, 400_000)
            likes = self.rng.randint(100, 30_000)
            cmts = self.rng.randint(0, 900)
            shrs = self.rng.randint(0, 2_000)
            videos.append({
                "id": vid, "profile_username": user, "create_time": when,
                "video_description": f"TikTok fixture {i} #frndos",
                "share_url": f"https://tiktok.com/@{user}/video/{vid}",
                "embed_url": f"https://tiktok.com/embed/{vid}",
                "cover_image_url": f"https://cdn.example/{vid}.jpg",
                "video_duration": self.rng.randint(8, 90),
                # Both spellings, on purpose — see REQUIRED_COLUMNS["tt"].
                # The left column is what `tiktok.yaml` allow-lists; the right
                # is what the transform actually reads.
                #
                # TikTok organic counts a view at 0 seconds — impression-like,
                # and NOT comparable with Meta's >=3s or YouTube's ~10s. This
                # is the reason `video_views` cannot be summed across channels.
                "view_count": views, "video_views": views,
                "like_count": likes, "likes": likes,
                "comment_count": cmts, "comments": cmts,
                "share_count": shrs, "shares": shrs,
                "caption": f"TikTok fixture {i} #frndos",
                "thumbnail_url": f"https://cdn.example/{vid}.jpg",
                "favorites": self.rng.randint(0, 5_000),
                "reach": self.rng.randint(4_000, 350_000),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            for c in range(self.rng.randint(0, 2)):
                comments.append({
                    "id": f"{vid}-c{c}", "video_id": vid, "create_time": when,
                    "text": "this is fire", "username": f"tt_user{c}",
                    "_fivetran_synced": when, "_fivetran_deleted": 0,
                })

        profile = [{
            "username": user, "display_name": "FRND Local TT",
            "followers_count": 212_000,
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        }]
        metric = [{
            "profile_username": user, "date": self.base + timedelta(days=d),
            "followers_count": 212_000 + d * 90,
            "daily_new_followers": self.rng.randint(30, 700),
            "daily_lost_followers": self.rng.randint(5, 200),
            "profile_views": self.rng.randint(1_000, 20_000),
            "unique_video_views": self.rng.randint(2_000, 60_000),
            "_fivetran_synced": self.base + timedelta(days=d), "_fivetran_deleted": 0,
        } for d in range(28)]
        age = [{
            # `age_group` is the allow-list name, `age` is what the flow reads.
            "profile_username": user, "age_group": b, "age": b,
            "percentage": round(p, 2),
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        } for b, p in (("18-24", 34.5), ("25-34", 41.0), ("35-44", 16.5), ("45-54", 8.0))]
        country = [{
            "profile_username": user, "country": c, "percentage": round(p, 2),
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        } for c, p in (("ID", 78.0), ("MY", 12.0), ("SG", 10.0))]

        return {
            "profile": profile, "video": videos, "profile_metric": metric,
            "profile_audience_age": age, "profile_audience_country": country,
            "comment": comments,
        }

    def rows_yt(self, contract):
        chan = self.registered_account("yt") or f"yt-chan-{self.brand[:8]}"
        videos, basic, comments, demo = [], [], [], []
        for i in range(self.posts):
            when = self.base + timedelta(days=i % 28, hours=i % 3)
            vid = f"yt-video-{i:04d}"
            videos.append({
                "id": vid, "snippet_channel_id": chan,
                "snippet_title": f"YouTube fixture {i}",
                "snippet_description": f"Local fixture video {i}",
                "snippet_published_at": when,
                "content_details_duration": f"PT{self.rng.randint(1, 12)}M{self.rng.randint(0, 59)}S",
                "statistics_view_count": self.rng.randint(2_000, 200_000),
                "statistics_like_count": self.rng.randint(50, 9_000),
                "statistics_comment_count": self.rng.randint(0, 700),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            views = self.rng.randint(1_500, 150_000)
            basic.append({
                "channel_id": chan, "video_id": vid, "date": when,
                "views": views,
                # `engaged_views` is roughly a 10-second threshold — a third
                # incompatible definition of "a view" in the same mart column.
                "engaged_views": int(views * 0.42),
                "likes": self.rng.randint(20, 8_000),
                "shares": self.rng.randint(0, 900),
                "comments": self.rng.randint(0, 600),
                "subscribers_gained": self.rng.randint(0, 400),
                "subscribers_lost": self.rng.randint(0, 90),
                "_fivetran_synced": when, "_fivetran_deleted": 0,
            })
            for c in range(self.rng.randint(0, 2)):
                comments.append({
                    "id": f"{vid}-c{c}", "video_id": vid,
                    "snippet_published_at": when, "snippet_updated_at": when,
                    "snippet_author_display_name": f"yt_user{c}",
                    "snippet_text_original": "underrated channel",
                    "_fivetran_synced": when, "_fivetran_deleted": 0,
                })
        for band, pct in (("age18-24", 26.0), ("age25-34", 38.5), ("age35-44", 21.5), ("age45-54", 14.0)):
            demo.append({
                "channel_id": chan, "date": self.base, "age_group": band,
                "views_percentage": pct,
                "_fivetran_synced": self.base, "_fivetran_deleted": 0,
            })

        channel = [{
            "id": chan, "snippet_title": "FRND Local YT",
            "snippet_custom_url": "@frndlocal",
            "statistics_subscriber_count": 64_000,
            "statistics_view_count": 4_100_000,
            "_fivetran_synced": self.base, "_fivetran_deleted": 0,
        }]
        return {
            "channel": channel, "video": videos, "channel_basic_a_2": basic,
            "channel_demographics_a_1": demo, "comment": comments,
        }

    def seed_platform(self, alias: str, drop: bool) -> dict:
        platform, yaml_name = PLATFORMS[alias]
        contract = load_contract(ORCH / "config_handover" / yaml_name)
        db = f"raw_{alias}_{self.brand}"

        if drop:
            self.ch.command(f"DROP DATABASE IF EXISTS `{db}`")
        self.ch.command(f"CREATE DATABASE IF NOT EXISTS `{db}`")

        builder = getattr(self, f"rows_{alias}")
        payload = builder(contract)

        written = {}
        for table, cols in contract.items():
            rows = payload.get(table, [])
            # Union the contract's columns with whatever the row builder set:
            # a builder may legitimately populate a column the allow-list omits
            # (the two drift), and dropping it silently would hide that.
            required = REQUIRED_COLUMNS.get((alias, table), [])
            extra = sorted(
                ({k for r in rows for k in r} | set(required))
                - set(cols) - set(FIVETRAN_META)
            )
            typed = self.create_table(db, table, cols + extra, rows)
            n = self.insert(db, table, typed, rows)
            written[table] = n
        self.log(f"  {db}")
        for t, n in written.items():
            self.log(f"    {t:38} {n:>6} rows")
        return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--brand", help="brand ULID; becomes raw_<alias>_<brand>")
    ap.add_argument("--platforms", default="ig,fb,tt,yt", help="comma list of ig,fb,tt,yt")
    ap.add_argument("--posts", type=int, default=40, help="posts/videos per platform")
    ap.add_argument("--seed", type=int, default=20260821, help="RNG seed — same seed, same fixture")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=8123)
    ap.add_argument("--user", default="default")
    ap.add_argument("--password", default="")
    ap.add_argument("--drop", action="store_true", help="DROP each raw db before recreating it")
    ap.add_argument("--list", action="store_true", help="show the contract tables and exit")
    args = ap.parse_args()

    if args.host not in ("localhost", "127.0.0.1"):
        print(f"refusing to run against '{args.host}' — this script is localhost-only", file=sys.stderr)
        return 2

    sys.path.insert(0, str(ORCH))

    if args.list:
        for alias, (platform, yaml_name) in PLATFORMS.items():
            contract = load_contract(ORCH / "config_handover" / yaml_name)
            print(f"\n{platform}  (raw_{alias}_<brand>)")
            for t, cols in contract.items():
                print(f"  {t:38} {len(cols):>3} columns")
        return 0

    if not args.brand:
        ap.error("--brand is required (or use --list)")

    import clickhouse_connect

    ch = clickhouse_connect.get_client(
        host=args.host, port=args.port, username=args.user,
        password=args.password, secure=False,
    )
    print(f"seeding brand {args.brand} on {args.host}:{args.port}\n")
    seeder = Seeder(ch, args.brand, args.posts, args.seed)
    total = 0
    for alias in [a.strip() for a in args.platforms.split(",") if a.strip()]:
        if alias not in PLATFORMS:
            print(f"unknown platform '{alias}' — expected one of {', '.join(PLATFORMS)}", file=sys.stderr)
            return 2
        total += sum(seeder.seed_platform(alias, args.drop).values())
    print(f"\n{total} raw rows written.")
    print("\nNext: run the transforms, then the mart loaders. See scripts/local-run-pipeline.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
