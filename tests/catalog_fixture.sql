--
-- tests/catalog_fixture.sql
--
-- A small data set for tests/catalog_smoke.sh, which loads it into a
-- scratch database after us3.sql and us3_procedures.sql.  The IDs start at
-- 900 so they stay clear of the special records us3.sql inserts.
--
-- People (password in brackets):
--   901 admin  (adminpw)  userlevel 3, an administrator
--   902 alice  (alicepw)  userlevel 2, an investigator
--   903 bob    (bobpw)    userlevel 2, an investigator
--   904 carol  (carolpw)  userlevel 2, a stranger who owns nothing
--
-- check_user() refuses userlevel 0 and 1 outright, so the ordinary users
-- are at 2 (analyst), which is still below @US3_ADMIN.
--
-- Experiments:
--   9101 smoke_alpha  alice's; linked to alice TWICE and to bob once, so
--                     experimentPerson has three rows for it.
--                     2 triples, 3 edits.
--                     models: 9401 alice, 9402 alice, 9403 bob (a model
--                             another investigator fitted to alice's edit),
--                             9404 with no modelPerson row at all.
--                     noise:  9501 (model 9401, alice), 9502 (9403, bob),
--                             9503 (9404, nobody's), 9504 (9401 on another
--                             edit, alice).
--   9102 smoke_beta   alice's, and empty.
--   9103 smoke_gamma  bob's; 1 triple, 1 edit, 1 model, 1 noise, all bob's.
--   9104 smoke_delta  linked to nobody; 1 triple.  Listed for no one, not
--                     even an administrator asking for everybody.
--
-- What each caller should see is spelled out in tests/catalog_smoke.sh.
--
-- The rows refer to an instrument, solution and channel that are not here;
-- the catalog procedures never read those tables, so foreign keys are
-- switched off while loading rather than building a lab to satisfy them.
--

SET @OLD_FOREIGN_KEY_CHECKS = @@FOREIGN_KEY_CHECKS;
SET FOREIGN_KEY_CHECKS = 0;

INSERT INTO people (personID, personGUID, fname, lname, email, password,
                    activated, userlevel, gmpReviewerRole, authenticatePAM,
                    userNamePAM)
VALUES (901, '00000000-0000-4000-8000-000000000901', 'Smoke', 'Admin',
        'smoke-admin@example.org', MD5('adminpw'), 1, 3, 'NONE', 0, 'smoke_admin'),
       (902, '00000000-0000-4000-8000-000000000902', 'Smoke', 'Alice',
        'smoke-alice@example.org', MD5('alicepw'), 1, 2, 'NONE', 0, 'smoke_alice'),
       (903, '00000000-0000-4000-8000-000000000903', 'Smoke', 'Bob',
        'smoke-bob@example.org',   MD5('bobpw'),   1, 2, 'NONE', 0, 'smoke_bob'),
       (904, '00000000-0000-4000-8000-000000000904', 'Smoke', 'Carol',
        'smoke-carol@example.org', MD5('carolpw'), 1, 2, 'NONE', 0, 'smoke_carol');

INSERT INTO project (projectID, projectGUID, description, status)
VALUES (9001, '00000000-0000-4000-8000-000000009001', 'Smoke project', 'submitted');

INSERT INTO experiment (experimentID, projectID, runID, instrumentID,
                        experimentGUID, type, runType, dateBegin, label)
VALUES (9101, 9001, 'smoke_alpha', 1, '00000000-0000-4000-8000-000000009101',
        'velocity', 'RI', '2026-01-01', 'alpha'),
       (9102, 9001, 'smoke_beta',  1, '00000000-0000-4000-8000-000000009102',
        'velocity', 'RI', '2026-01-02', 'beta'),
       (9103, NULL, 'smoke_gamma', 1, '00000000-0000-4000-8000-000000009103',
        'velocity', 'IP', '2026-01-03', 'gamma'),
       (9104, NULL, 'smoke_delta', 1, '00000000-0000-4000-8000-000000009104',
        'velocity', 'RI', '2026-01-04', 'delta');

INSERT INTO experimentPerson (experimentID, personID)
VALUES (9101, 902), (9101, 902), (9101, 903),
       (9102, 902),
       (9103, 903);

INSERT INTO rawData (rawDataID, rawDataGUID, label, filename, data, comment,
                     experimentID, solutionID, channelID)
VALUES (9201, '00000000-0000-4000-8000-000000009201', 'smoke_alpha',
        'smoke_alpha.RI.1.A.280.auc', 'RAW-9201', '', 9101, 1, 1),
       (9202, '00000000-0000-4000-8000-000000009202', 'smoke_alpha',
        'smoke_alpha.RI.1.A.290.auc', 'RAW-9202', '', 9101, 1, 1),
       (9203, '00000000-0000-4000-8000-000000009203', 'smoke_gamma',
        'smoke_gamma.IP.1.A.660.auc', 'RAW-9203', '', 9103, 1, 1),
       (9204, '00000000-0000-4000-8000-000000009204', 'smoke_delta',
        'smoke_delta.RI.1.A.280.auc', 'RAW-9204', '', 9104, 1, 1);

INSERT INTO editedData (editedDataID, rawDataID, editGUID, label, data,
                        filename, comment)
VALUES (9301, 9201, '00000000-0000-4000-8000-000000009301', 'smoke_alpha',
        'EDIT-9301', 'smoke_alpha.2601011200.RI.1.A.280.xml', ''),
       (9302, 9201, '00000000-0000-4000-8000-000000009302', 'smoke_alpha',
        'EDIT-9302', 'smoke_alpha.2601011300.RI.1.A.280.xml', ''),
       (9303, 9202, '00000000-0000-4000-8000-000000009303', 'smoke_alpha',
        'EDIT-9303', 'smoke_alpha.2601011200.RI.1.A.290.xml', ''),
       (9304, 9203, '00000000-0000-4000-8000-000000009304', 'smoke_gamma',
        'EDIT-9304', 'smoke_gamma.2601031200.IP.1.A.660.xml', '');

INSERT INTO model (modelID, editedDataID, modelGUID, description, xml)
VALUES (9401, 9301, '00000000-0000-4000-8000-000000009401',
        'smoke_alpha.1A280.2dsa.model', '<model id="9401"/>'),
       (9402, 9302, '00000000-0000-4000-8000-000000009402',
        'smoke_alpha.1A280.2dsa-fm.model', '<model id="9402"/>'),
       (9403, 9301, '00000000-0000-4000-8000-000000009403',
        'smoke_alpha.1A280.ga.model', '<model id="9403"/>'),
       (9404, 9303, '00000000-0000-4000-8000-000000009404',
        'smoke_alpha.1A290.2dsa.model', '<model id="9404"/>'),
       (9405, 9304, '00000000-0000-4000-8000-000000009405',
        'smoke_gamma.1A660.2dsa.model', '<model id="9405"/>');

-- 9404 deliberately has no modelPerson row
INSERT INTO modelPerson (modelID, personID)
VALUES (9401, 902), (9402, 902), (9403, 903), (9405, 903);

INSERT INTO noise (noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                   noiseType, description, xml)
VALUES (9501, '00000000-0000-4000-8000-000000009501', 9301, 9401,
        '00000000-0000-4000-8000-000000009401', 'ti_noise',
        'smoke_alpha.1A280.2dsa.ti_noise', '<noise id="9501"/>'),
       (9502, '00000000-0000-4000-8000-000000009502', 9301, 9403,
        '00000000-0000-4000-8000-000000009403', 'ri_noise',
        'smoke_alpha.1A280.ga.ri_noise', '<noise id="9502"/>'),
       (9503, '00000000-0000-4000-8000-000000009503', 9303, 9404,
        '00000000-0000-4000-8000-000000009404', 'ti_noise',
        'smoke_alpha.1A290.2dsa.ti_noise', '<noise id="9503"/>'),
       (9504, '00000000-0000-4000-8000-000000009504', 9302, 9401,
        '00000000-0000-4000-8000-000000009401', 'ri_noise',
        'smoke_alpha.1A280.2dsa.ri_noise', '<noise id="9504"/>'),
       (9505, '00000000-0000-4000-8000-000000009505', 9304, 9405,
        '00000000-0000-4000-8000-000000009405', 'ti_noise',
        'smoke_gamma.1A660.2dsa.ti_noise', '<noise id="9505"/>');

SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS;
