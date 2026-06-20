CREATE OR REPLACE MATERIALIZED LAKE VIEW bronze.bronze_fo.mlv_bronze_hcmworker
TBLPROPERTIES (delta.enableChangeDataFeed = true)
AS
WITH dir_party AS (
    SELECT
        dpt.recid                            AS RecId,
        dpt.partynumber                      AS PartyNumber,
        dpt.name                             AS Name,
        dpt.knownas                          AS KnownAs
    FROM bronze.sc_bronze_fo.dirpartytable dpt
    WHERE NOT (dpt.IsDelete <=> 1)
),
person_user AS (
    -- bridge: one F&O user account per person (DirPerson RecId)
    SELECT
        dpu.personparty                      AS PersonParty,
        su.fno_id                            AS UserId
    FROM bronze.sc_bronze_fo.dirpersonuser dpu
    INNER JOIN bronze.sc_bronze_fo.sysuserinfo su
        ON  su.fno_id = dpu.`user`
        AND NOT (su.IsDelete <=> 1)
    WHERE NOT (dpu.IsDelete <=> 1)
)
SELECT DISTINCT
    hw.recid                                 AS RecId,
    hw.personnelnumber                       AS PersonnelNumber,
    dp.PartyNumber                           AS PartyNumber,
    dp.Name                                  AS Name,
    hw.recid                                 AS RecIdCopy1,
    COALESCE(dp.KnownAs,'')                  AS KnownAs,
    COALESCE(pu.UserId, '')                  AS User,
    hw.createddatetime                       AS import_timestamp
FROM bronze.sc_bronze_fo.hcmworker hw
INNER JOIN dir_party dp
    ON dp.RecId = hw.person
LEFT JOIN person_user pu
    ON pu.PersonParty = hw.person
WHERE NOT (hw.IsDelete <=> 1);