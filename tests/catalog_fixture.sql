--
-- tests/catalog_fixture.sql
--
-- A small data set for tests/catalog_smoke.sh, which loads it into a
-- scratch database after us3.sql and us3_procedures.sql.  The IDs start at
-- 900 so they stay clear of the special records us3.sql inserts -- except
-- experiment 1, on purpose (see below).
--
-- People (password in brackets):
--   901 admin  (adminpw)  userlevel 3, an administrator
--   902 alice  (alicepw)  userlevel 2, an investigator
--   903 bob    (bobpw)    userlevel 2, an investigator
--   904 carol  (carolpw)  userlevel 2, a stranger who owns nothing
--   905 dave   (davepw)   userlevel 2, never activated        -> INACTIVE
--   906 erin   (erinpw)   userlevel 2, disabled by an admin   -> INACTIVE
--   907 frank  (frankpw)  userlevel 1, below analyst           -> BADPASS
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
--   9103 smoke_gamma  bob's; 1 triple, 1 edit, 1 model (9405), all bob's.
--                     noise: 9505, and 9508 -- global-fit noise: computed
--                     from alpha's edit 9303 but fitted with 9405, so it
--                     is gamma's noise, not alpha's.
--   9104 smoke_delta  linked to nobody; 1 triple.  Listed for no one, not
--                     even an administrator asking for everybody.
--      1 smoke_magic  bob's; 1 triple, 1 edit, model 9406 and noise 9507,
--                     bob's.  verify_experiment_permission() lets anyone
--                     read experiment 1; the catalog procedures must not.
--
-- And model 9407 of alice's on the UNASSIGNED edit 1, with noise 9509
-- computed from alpha's edit 9301: neither is in any experiment.
--
-- Within smoke_alpha the record IDs are deliberately NOT in the order the
-- procedures sort by (file name; noise by time entered, newest first), and
-- runIDs are not in experimentID order, so a lost ORDER BY shows.  Every
-- timestamp is fixed, so the smoke test knows what the UTC_ columns hold.
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
                    activated, account_enabled, userlevel, gmpReviewerRole,
                    authenticatePAM, userNamePAM)
VALUES (901, '00000000-0000-4000-8000-000000000901', 'Smoke', 'Admin',
        'smoke-admin@example.org', MD5('adminpw'), 1, 1, 3, 'NONE', 0, 'smoke_admin'),
       (902, '00000000-0000-4000-8000-000000000902', 'Smoke', 'Alice',
        'smoke-alice@example.org', MD5('alicepw'), 1, 1, 2, 'NONE', 0, 'smoke_alice'),
       (903, '00000000-0000-4000-8000-000000000903', 'Smoke', 'Bob',
        'smoke-bob@example.org',   MD5('bobpw'),   1, 1, 2, 'NONE', 0, 'smoke_bob'),
       (904, '00000000-0000-4000-8000-000000000904', 'Smoke', 'Carol',
        'smoke-carol@example.org', MD5('carolpw'), 1, 1, 2, 'NONE', 0, 'smoke_carol'),
       (905, '00000000-0000-4000-8000-000000000905', 'Smoke', 'Dave',
        'smoke-dave@example.org',  MD5('davepw'),  0, 1, 2, 'NONE', 0, 'smoke_dave'),
       (906, '00000000-0000-4000-8000-000000000906', 'Smoke', 'Erin',
        'smoke-erin@example.org',  MD5('erinpw'),  1, 0, 2, 'NONE', 0, 'smoke_erin'),
       (907, '00000000-0000-4000-8000-000000000907', 'Smoke', 'Frank',
        'smoke-frank@example.org', MD5('frankpw'), 1, 1, 1, 'NONE', 0, 'smoke_frank');

INSERT INTO project (projectID, projectGUID, description, status)
VALUES (9001, '00000000-0000-4000-8000-000000009001', 'Smoke project', 'submitted');

INSERT INTO experiment (experimentID, projectID, runID, instrumentID,
                        experimentGUID, type, runType, dateBegin, label,
                        dateUpdated)
VALUES (1,    NULL, 'smoke_magic', 1, '00000000-0000-4000-8000-000000009100',
        'velocity', 'RI', '2026-01-05', 'magic', '2026-01-05 10:00:00'),
       (9101, 9001, 'smoke_alpha', 1, '00000000-0000-4000-8000-000000009101',
        'velocity', 'RI', '2026-01-01', 'alpha', '2026-01-01 10:00:00'),
       (9102, 9001, 'smoke_beta',  1, '00000000-0000-4000-8000-000000009102',
        'velocity', 'RI', '2026-01-02', 'beta',  '2026-01-02 10:00:00'),
       (9103, NULL, 'smoke_gamma', 1, '00000000-0000-4000-8000-000000009103',
        'velocity', 'IP', '2026-01-03', 'gamma', '2026-01-03 10:00:00'),
       (9104, NULL, 'smoke_delta', 1, '00000000-0000-4000-8000-000000009104',
        'velocity', 'RI', '2026-01-04', 'delta', '2026-01-04 10:00:00');

INSERT INTO experimentPerson (experimentID, personID)
VALUES (9101, 902), (9101, 902), (9101, 903),
       (9102, 902),
       (9103, 903),
       (1,    903);

-- In smoke_alpha, 9201 sorts after 9202 by file name
INSERT INTO rawData (rawDataID, rawDataGUID, label, filename, data, comment,
                     experimentID, solutionID, channelID, lastUpdated)
VALUES (9201, '00000000-0000-4000-8000-000000009201', 'smoke_alpha',
        'smoke_alpha.RI.2.A.280.auc', 'RAW-9201', 'cell 2', 9101, 1, 1,
        '2026-01-01 11:00:00'),
       (9202, '00000000-0000-4000-8000-000000009202', 'smoke_alpha',
        'smoke_alpha.RI.1.A.290.auc', 'RAW-9202x', 'cell 1', 9101, 1, 1,
        '2026-01-01 11:30:00'),
       (9203, '00000000-0000-4000-8000-000000009203', 'smoke_gamma',
        'smoke_gamma.IP.1.A.660.auc', 'RAW-9203', '', 9103, 1, 1,
        '2026-01-03 11:00:00'),
       (9204, '00000000-0000-4000-8000-000000009204', 'smoke_delta',
        'smoke_delta.RI.1.A.280.auc', 'RAW-9204', '', 9104, 1, 1,
        '2026-01-04 11:00:00'),
       (9205, '00000000-0000-4000-8000-000000009205', 'smoke_magic',
        'smoke_magic.RI.1.A.280.auc', 'RAW-9205', '', 1, 1, 1,
        '2026-01-05 11:00:00');

-- By file name smoke_alpha's edits are 9303, 9301, 9302
INSERT INTO editedData (editedDataID, rawDataID, editGUID, label, data,
                        filename, comment, lastUpdated)
VALUES (9301, 9201, '00000000-0000-4000-8000-000000009301', 'smoke_alpha',
        'EDIT-9301', 'smoke_alpha.2601011200.RI.2.A.280.xml', '',
        '2026-01-01 12:00:00'),
       (9302, 9201, '00000000-0000-4000-8000-000000009302', 'smoke_alpha',
        'EDIT-9302xx', 'smoke_alpha.2601011300.RI.2.A.280.xml', '',
        '2026-01-01 13:00:00'),
       (9303, 9202, '00000000-0000-4000-8000-000000009303', 'smoke_alpha',
        'EDIT-9303x', 'smoke_alpha.2601011200.RI.1.A.290.xml', '',
        '2026-01-01 12:30:00'),
       (9304, 9203, '00000000-0000-4000-8000-000000009304', 'smoke_gamma',
        'EDIT-9304', 'smoke_gamma.2601031200.IP.1.A.660.xml', '',
        '2026-01-03 12:00:00'),
       (9305, 9205, '00000000-0000-4000-8000-000000009305', 'smoke_magic',
        'EDIT-9305', 'smoke_magic.2601051200.RI.1.A.280.xml', '',
        '2026-01-05 12:00:00');

INSERT INTO model (modelID, editedDataID, modelGUID, description, variance,
                   meniscus, xml, lastUpdated)
VALUES (9401, 9301, '00000000-0000-4000-8000-000000009401',
        'smoke_alpha.1A280.2dsa.model', 0.25, 5.875, '<model id="9401"/>',
        '2026-01-01 14:00:00'),
       (9402, 9302, '00000000-0000-4000-8000-000000009402',
        'smoke_alpha.1A280.2dsa-fm.model', 0.5, 6.125, '<model id="9402"/>',
        '2026-01-01 14:30:00'),
       (9403, 9301, '00000000-0000-4000-8000-000000009403',
        'smoke_alpha.1A280.ga.model', 0.75, 5.9375, '<model id="9403"/>',
        '2026-01-01 15:00:00'),
       (9404, 9303, '00000000-0000-4000-8000-000000009404',
        'smoke_alpha.1A290.2dsa.model', 1, 6, '<model id="9404"/>',
        '2026-01-01 15:30:00'),
       (9405, 9304, '00000000-0000-4000-8000-000000009405',
        'smoke_gamma.1A660.2dsa.model', 1.5, 6.5, '<model id="9405"/>',
        '2026-01-03 14:00:00'),
       (9406, 9305, '00000000-0000-4000-8000-000000009406',
        'smoke_magic.1A280.2dsa.model', 2, 7, '<model id="9406"/>',
        '2026-01-05 14:00:00'),
       (9407, 1,    '00000000-0000-4000-8000-000000009407',
        'smoke_unassigned.2dsa.model', 3, 7.5, '<model id="9407"/>',
        '2026-01-06 14:00:00');

-- 9404 deliberately has no modelPerson row
INSERT INTO modelPerson (modelID, personID)
VALUES (9401, 902), (9402, 902), (9403, 903), (9405, 903), (9406, 903),
       (9407, 902);

-- By time entered, newest first, smoke_alpha's noise is 9502, 9504, 9501
-- (9503 is nobody's)
INSERT INTO noise (noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                   noiseType, description, xml, timeEntered)
VALUES (9501, '00000000-0000-4000-8000-000000009501', 9301, 9401,
        '00000000-0000-4000-8000-000000009401', 'ti_noise',
        'smoke_alpha.1A280.2dsa.ti_noise', '<noise id="9501"/>',
        '2026-01-01 16:00:00'),
       (9502, '00000000-0000-4000-8000-000000009502', 9301, 9403,
        '00000000-0000-4000-8000-000000009403', 'ri_noise',
        'smoke_alpha.1A280.ga.ri_noise', '<noise id="9502"/>',
        '2026-01-01 18:00:00'),
       (9503, '00000000-0000-4000-8000-000000009503', 9303, 9404,
        '00000000-0000-4000-8000-000000009404', 'ti_noise',
        'smoke_alpha.1A290.2dsa.ti_noise', '<noise id="9503"/>',
        '2026-01-01 16:30:00'),
       (9504, '00000000-0000-4000-8000-000000009504', 9302, 9401,
        '00000000-0000-4000-8000-000000009401', 'ri_noise',
        'smoke_alpha.1A280.2dsa.ri_noise', '<noise id="9504"/>',
        '2026-01-01 17:00:00'),
       (9505, '00000000-0000-4000-8000-000000009505', 9304, 9405,
        '00000000-0000-4000-8000-000000009405', 'ti_noise',
        'smoke_gamma.1A660.2dsa.ti_noise', '<noise id="9505"/>',
        '2026-01-03 16:00:00'),
       (9507, '00000000-0000-4000-8000-000000009507', 9305, 9406,
        '00000000-0000-4000-8000-000000009406', 'ti_noise',
        'smoke_magic.1A280.2dsa.ti_noise', '<noise id="9507"/>',
        '2026-01-05 16:00:00'),
       -- global fit: computed from alpha's edit, fitted with gamma's model
       (9508, '00000000-0000-4000-8000-000000009508', 9303, 9405,
        '00000000-0000-4000-8000-000000009405', 'ti_noise',
        'smoke_alpha.1A290.global.ti_noise', '<noise id="9508"/>',
        '2026-01-03 17:00:00'),
       -- fitted with a model on the UNASSIGNED edit: in no experiment
       (9509, '00000000-0000-4000-8000-000000009509', 9301, 9407,
        '00000000-0000-4000-8000-000000009407', 'ri_noise',
        'smoke_alpha.1A280.unassigned.ri_noise', '<noise id="9509"/>',
        '2026-01-06 16:00:00');

SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS;
