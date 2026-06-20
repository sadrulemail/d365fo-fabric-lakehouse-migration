# Data Migration: D365 F&O → Microsoft Fabric Lakehouse via Dataverse

End-to-end architecture for landing Dynamics 365 Finance & Operations (F&O) data into
Microsoft Fabric using **Dataverse Link to Fabric**, creating **shortcuts** from the
landing lakehouse into a curated lakehouse, transforming with **Materialized Lake Views
(MLVs)** across a medallion (bronze → silver → gold) architecture, and exposing a
**semantic model** for reporting.

---

## 1. High-Level Architecture

```
┌────────────────┐   Synapse Link /    ┌──────────────────┐
│   D365 F&O      │   Dataverse Link    │   Dataverse      │
│ (Finance & Ops) │ ──────────────────► │ (CDM/entities)   │
└────────────────┘   to Fabric         └──────────────────┘
                                                 │
                                                 │  Link to Fabric
                                                 │  (no-copy, near real-time)
                                                 ▼
                                   ┌─────────────────────────────┐
                                   │  LANDING Lakehouse           │
                                   │  (Dataverse-managed,         │
                                   │   read-only Delta tables)    │
                                   └─────────────────────────────┘
                                                 │
                                                 │  OneLake Shortcuts (zero-copy)
                                                 ▼
                ┌────────────────────────────────────────────────────────┐
                │  CURATED Lakehouse  (medallion)                         │
                │                                                         │
                │  bronze (shortcuts) ──MLV──► silver ──MLV──► gold       │
                └────────────────────────────────────────────────────────┘
                                                 │
                                                 │  Direct Lake
                                                 ▼
                                   ┌─────────────────────────────┐
                                   │  Semantic Model + Power BI   │
                                   └─────────────────────────────┘
```

**Key principle:** data is **never physically copied** between Dataverse → landing → bronze.
Link to Fabric and OneLake shortcuts are both *zero-copy* virtualization. The first real
materialization happens at the **silver** layer when MLVs transform the data.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| D365 F&O environment | Finance & Operations apps backed by Dataverse |
| Dataverse environment | Same tenant; **Managed Lake** / "Link to Microsoft Fabric" enabled |
| Microsoft Fabric capacity | F2+ (or P/F SKU); trial works for POC |
| Fabric workspace | One workspace assigned to the Fabric capacity |
| Permissions | Dataverse System Administrator + Fabric Workspace **Admin/Member** |
| F&O tables in Dataverse | Enable **virtual entities / Finance and Operations data** so F&O tables surface in Dataverse |
| Storage | OneLake (automatic with Fabric) |

> **F&O note:** F&O tables are not natively Dataverse rows. You expose them through
> **Finance and Operations virtual entities** (or the *export to Dataverse* / dual-write
> feature) so that the F&O tables/entities appear in Dataverse and are then carried into
> Fabric by Link to Fabric.

---

## 3. Step 1 — Link Dataverse (with F&O data) to Fabric

This creates the **landing lakehouse** automatically. No pipelines, no copy jobs.

1. Go to **Power Apps** (`make.powerapps.com`) → select the environment connected to F&O.
2. Left nav → **Tables** → **Analyze** → **Link to Microsoft Fabric**.
3. Select the F&O / Dataverse tables to include (e.g. `CustTable`, `VendTable`,
   `LedgerJournalTrans`, `SalesLine`, `InventTrans`, etc.).
4. Choose the target **Fabric workspace** and confirm.
5. Dataverse provisions a **managed Lakehouse** in that workspace containing **Delta
   Parquet** versions of every selected table, kept in continuous sync.

**Result:** a lakehouse (here called `landing`) whose `Tables/` folder holds read-only,
auto-synced Delta tables. You **cannot** write to or transform these directly — that's why
we shortcut them into a curated lakehouse.

> Sync is **incremental and near real-time** (driven by Dataverse change tracking).
> Schema/column changes in F&O propagate automatically.

---

## 4. Step 2 — Create the Curated Lakehouse + Shortcuts (bronze)

Create a **second lakehouse** (`curated`) that you own and can transform in. Bring the
landing tables in as **OneLake shortcuts** — pointers, not copies.

### Create the lakehouse
1. In the Fabric workspace → **New** → **Lakehouse** → name it `curated` (or `lh_medallion`).

### Create shortcuts (bronze layer)
For each landing table:
1. In `curated` lakehouse → **Tables** → **⋯ New shortcut**.
2. Source = **Microsoft OneLake** → pick the `landing` lakehouse → select the table(s).
3. The table now appears under `curated/Tables/` as a shortcut.

> Tip: place shortcuts under a `bronze` schema (schema-enabled lakehouse) so the medallion
> layers are visually separated: `curated.bronze.CustTable`, etc.

**Why shortcut instead of copy:**
- Zero storage duplication and zero ETL latency for the raw layer.
- Always reflects the latest Dataverse/F&O sync.
- Curated lakehouse stays the single transformation surface for silver/gold MLVs.

#### Optional: script shortcut creation
Shortcuts can be created in bulk via the Fabric REST API (OneLake Shortcuts API) instead of
clicking each one:

```http
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{lakehouseId}/shortcuts
Content-Type: application/json
Authorization: Bearer {token}

{
  "path": "Tables/bronze",
  "name": "CustTable",
  "target": {
    "oneLake": {
      "workspaceId": "{landingWorkspaceId}",
      "itemId": "{landingLakehouseId}",
      "path": "Tables/CustTable"
    }
  }
}
```

Loop this over your table list to provision the whole bronze layer.

---

## 5. Step 3 — Transform with Materialized Lake Views (silver → gold)

**Materialized Lake Views (MLVs)** are declarative, SQL-defined views that Fabric
**materializes as managed Delta tables** and refreshes on a schedule, with built-in
**lineage** and **data-quality constraints**. They are the transformation engine of the
medallion model.

### 5.1 Silver — clean, conform, deduplicate

Silver MLVs read from the bronze shortcuts, apply typing/cleansing, standardize names,
handle nulls, and enforce keys.

```sql
-- Silver: cleansed customer master
CREATE MATERIALIZED LAKE VIEW IF NOT EXISTS silver.dim_customer
(
    CONSTRAINT valid_account_num CHECK (account_num IS NOT NULL) ON MISMATCH DROP
)
AS
SELECT
    CAST(AccountNum            AS STRING)  AS account_num,
    TRIM(Name)                            AS customer_name,
    CAST(CreditMax            AS DECIMAL(18,2)) AS credit_limit,
    UPPER(CurrencyCode)                    AS currency_code,
    CAST(ModifiedDateTime    AS TIMESTAMP) AS modified_at
FROM bronze.CustTable
WHERE IsDelete IS NULL OR IsDelete = false;   -- drop soft-deleted Dataverse rows
```

Key MLV features used here:
- `CONSTRAINT ... ON MISMATCH DROP | FAIL` — data-quality enforcement at refresh time.
- Soft-delete filtering (`IsDelete`) — Dataverse marks deletes rather than removing rows.
- Deterministic typing from F&O's loosely-typed staged columns.

### 5.2 Gold — business aggregates / star schema

Gold MLVs join conformed silver entities into facts and dimensions ready for the semantic
model.

```sql
-- Gold: sales fact by customer / date
CREATE MATERIALIZED LAKE VIEW IF NOT EXISTS gold.fact_sales AS
SELECT
    sl.sales_id,
    c.account_num,
    c.customer_name,
    CAST(sl.invoice_date AS DATE)        AS invoice_date,
    SUM(sl.line_amount)                  AS line_amount,
    SUM(sl.qty)                          AS quantity
FROM silver.fact_sales_line   sl
JOIN silver.dim_customer      c  ON sl.account_num = c.account_num
GROUP BY sl.sales_id, c.account_num, c.customer_name, CAST(sl.invoice_date AS DATE);
```

### 5.3 Orchestration & refresh

- MLVs are authored in a **Lakehouse SQL / notebook** or the MLV definition surface and
  organized into a **lineage graph** that Fabric schedules automatically.
- Set a **refresh schedule** (e.g. every 1–4 h, or daily) on the MLV graph; Fabric refreshes
  in dependency order (bronze shortcut → silver → gold).
- Because bronze are shortcuts to the auto-synced landing lakehouse, each MLV refresh always
  reads the latest F&O data — no separate ingestion step.
- Monitor freshness and constraint violations in the **MLV lineage / run history** view.

> This mirrors the existing **Fabric medallion MLV** project pattern
> (`D:\Fabric\scripts\`): silver/unit_test MLVs live in the `bronze` DB; validate with the
> `fabric-validate` tooling at `D:\Fabric\scripts\validation\`.

---

## 6. Step 4 — Semantic Model (Direct Lake) + Power BI

Expose the **gold** layer to reporting with a **Direct Lake** semantic model — query speed of
import, freshness of DirectQuery, no data copy.

1. In the `curated` lakehouse → **New semantic model** (or use the default one).
2. Select the **gold** tables (`fact_sales`, `dim_customer`, `dim_date`, …).
3. Define the model:
   - **Relationships** — e.g. `fact_sales[account_num]` → `dim_customer[account_num]`,
     `fact_sales[invoice_date]` → `dim_date[date]`.
   - **Measures (DAX)**:
     ```DAX
     Total Sales   = SUM(fact_sales[line_amount])
     Total Qty     = SUM(fact_sales[quantity])
     Avg Order Val = DIVIDE([Total Sales], DISTINCTCOUNT(fact_sales[sales_id]))
     ```
   - **Hide** key/technical columns; format currency/date columns.
   - Mark `dim_date` as the **date table**.
4. **Direct Lake mode** reads the gold Delta files directly from OneLake — refreshes follow
   the MLV refresh automatically. (Falls back to DirectQuery only if a query exceeds Direct
   Lake guardrails.)
5. Build **Power BI reports** on top, or let users connect via the OneLake/XMLA endpoint.

---

## 7. End-to-End Data Flow Summary

| Stage | Mechanism | Copy? | Refresh |
|---|---|---|---|
| F&O → Dataverse | Virtual entities / dual-write | No (virtual) | Real-time |
| Dataverse → Landing LH | **Link to Fabric** | No (managed Delta) | Near real-time, incremental |
| Landing → Curated bronze | **OneLake shortcut** | No (pointer) | Instant (live) |
| bronze → silver → gold | **Materialized Lake Views** | Yes (materialized Delta) | Scheduled, dependency-ordered |
| gold → reporting | **Direct Lake semantic model** | No | Follows MLV refresh |

---

## 8. Design Considerations & Best Practices

- **Schema-enabled lakehouse:** use schemas (`bronze`/`silver`/`gold`) to keep layers clean
  and make MLV lineage readable.
- **Soft deletes:** always filter Dataverse `IsDelete = true` rows in silver; Link to Fabric
  carries deletes as flags, not physical removals.
- **Incremental vs full:** MLVs currently full-refresh their definition; design silver to be
  cheap, push heavy joins/aggregation to gold, and partition large facts by date.
- **Naming:** keep F&O technical names in bronze (audit/traceability), apply business names
  in silver/gold.
- **Data quality:** use MLV `CONSTRAINT … ON MISMATCH FAIL` for critical keys so bad loads
  halt rather than propagate.
- **Security:** apply workspace roles + (optionally) **OneLake data access roles** / RLS in
  the semantic model. Shortcuts inherit source permissions.
- **Cost/capacity:** shortcuts + Direct Lake minimize storage; the main CU consumption is MLV
  refresh — tune the schedule to business SLAs.
- **Lineage & validation:** rely on MLV lineage for dependency tracking; reconcile row counts
  / keys between layers using the `fabric-validate` skill (silver vs unit_test MLVs).
- **Monitoring:** watch Link to Fabric sync health in Power Apps, MLV run history in Fabric,
  and semantic model refresh in the workspace.

---

## 9. Quick Checklist

- [ ] Enable F&O data in Dataverse (virtual entities / export to Dataverse)
- [ ] Link to Fabric → creates **landing** lakehouse (auto-sync Delta)
- [ ] Create **curated** lakehouse (schema-enabled)
- [ ] Shortcut landing tables into `curated.bronze`
- [ ] Author **silver** MLVs (clean, type, dedupe, drop soft-deletes, constraints)
- [ ] Author **gold** MLVs (facts + dimensions / star schema)
- [ ] Schedule MLV refresh (dependency-ordered)
- [ ] Build **Direct Lake** semantic model on gold (relationships + DAX measures)
- [ ] Validate layer-to-layer with `fabric-validate`
- [ ] Build Power BI reports
