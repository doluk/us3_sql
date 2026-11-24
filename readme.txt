readme.txt

US3 Database and Stored Procedures Reference

For notes and a US3 Stored Procedures API reference see the US3 wiki.

the new instance creation relies on the database definition
(us3.sql), all the stored procedures, and the lims code to create a new
instance. The way I do it, I become the us3 user and run the
update-local.sh script first thing. This will update the us3 user's copy of
all of these files from subversion. Then I run the create new instance
stuff.

If any time you forget to update the code first it's not a terribly big
deal. You can do a subversion update of the lims code, and you can update
the stored procedures like this:

mysql -u user -p database <us3_procedures.sql

That file sources all the other sql files. If the us3.sql file was out of
date it's a little more difficult, because there are some records that get
populated in there as part of the setup process too. However, I believe I
have scripts that can be used to refresh that too.


Catalog procedures (us3_catalog_procs.sql, release 4.3.0-dev)

us3_catalog_procs.sql adds the procedures behind UltraScan3's data
catalog (us_manage_data, us_data_publication): get_experiment_summary,
get_rawData_by_experiment, get_editedData_by_experiment,
get_model_desc_by_experiment, get_noise_desc_by_experiment,
get_rawData_by_person and get_editedData_by_person, and the function
verify_catalog_experiment they use.  It only adds procedures; no table
changes.  us3_procedures.sql sources it, so an existing instance gets them
by re-running that file as above, or this file alone:

mysql -u user -p database <us3_catalog_procs.sql

Clients that find these procedures missing fall back on the older
one-record-at-a-time procedures, so nothing breaks on an instance that has
not been updated -- it is only slow to browse, which is easy to miss.
Clients treat two server errors as "missing": 1305 (the procedure does
not exist) and 1370 (it exists, but the account has no EXECUTE privilege
on it, as after creating the procedures as one account and granting
EXECUTE on the old ones only).  Anything else is an error, so a database
must not keep a procedure of the same name with a different parameter
list (error 1318).  Re-run the whole file rather than parts of it: the
catalog uses the procedures in three groups (listing, per experiment,
whole store) and falls back for each group on its own.

The header of us3_catalog_procs.sql documents the status codes these
procedures answer with, whose records they list, and in which experiment
a record is counted (a noise record: in its model's).
tests/catalog_smoke.sh checks them against a scratch database, and
tests/catalog_mutations.sh checks that the smoke test catches broken
copies of them; see tests/README.


Logins hold a lock on the person's row (check_user and people.lastLogin)

Every procedure that takes a personGUID and password logs the caller in
with check_user() (us3_procedures.sql), and a successful login UPDATEs
people.lastLogin for that person.  The UPDATE takes an exclusive lock on
the person's people row until the transaction ends.  Normally each call
is its own transaction and the lock is released at once.  But a client
that opens a transaction and calls procedures inside it -- UltraScan3's
data import does, for the whole import -- keeps the row locked until it
commits or rolls back.  Meanwhile every other connection logging in as the
same investigator waits in check_user(): a second program browsing the
same data stalls, and fails with error 1205 (lock wait timeout) after
innodb_lock_wait_timeout, 50 s by default.  Other investigators are not
affected.  Reproduced on MySQL 8.0.46 and MariaDB 10.11.

check_user() is unchanged for now.  What was tried:

  - Skipping the UPDATE when lastLogin is recent (say within 10 minutes),
    read with a plain SELECT first.  This removes the stall whenever the
    client logged in -- outside its transaction -- shortly before opening
    it, which is what UltraScan3 does when it connects, and the
    transaction is shorter than that window: inside it, no login writes.
    Once the window passes during the transaction, the next login inside
    it writes and locks the row, and other logins wait again.  The cost
    is that lastLogin becomes accurate only to the window.

  - Skipping the UPDATE when the row is locked (SELECT ... FOR UPDATE SKIP
    LOCKED first) did not help: MySQL 8.0 ignores SKIP LOCKED inside a
    stored function, so check_user() still waited there, and on MariaDB
    10.11 check_user() waited all the same.  SKIP LOCKED is also missing
    from MariaDB before 10.6 and MySQL before 8.0, where check_user()
    would no longer load at all.

        -- in check_user(), with lastLogin read into l_lastLogin
        IF ( l_lastLogin IS NULL OR
             l_lastLogin < NOW() - INTERVAL 10 MINUTE ) THEN
          UPDATE people SET lastLogin = NOW() WHERE personID = @US3_ID;
        END IF;

  - The complete fix is to stop writing on every call: record lastLogin
    once per session, in a login procedure a client calls when it
    connects (outside any transaction), and let check_user() only read.
    That needs every client that relies on lastLogin being kept up to
    date (the LIMS web pages included) to call it, so it is a change to
    agree on rather than to make here.

Until then a client should keep transactions short, log in (call any
procedure) just before opening one, and expect error 1205 in other
programs of the same investigator while a long transaction is open.


delete_editedData and create_buffer_component (changed behaviour)

delete_editedData (us3_expdata_procs.sql) now:

  - allows an edit to an administrator and to anyone with an
    experimentPerson row for its experiment, also for experiment 1 (it
    used verify_editData_permission(), which opens experiment 1 to
    anybody).  It calls verify_catalog_experiment() from
    us3_catalog_procs.sql, so load that file too when loading
    us3_expdata_procs.sql on its own;
  - answers @NO_EDITDATA (510) for an edit that does not exist (it
    answered @NO_EXPERIMENT, 508);
  - refuses with @NOTPERMITTED (201), deleting nothing, when the models
    or noise it would take along include a model autoflowModelsLink
    refers to (GMP) or noise fitted with one -- for administrators too --
    or, for anyone but an administrator, another investigator's model
    (modelPerson) or noise fitted with one.  The message says which
    ("... records the GMP framework refers to (...)" or "... records of
    another investigator, which only an administrator may delete (...)")
    and lists the record IDs;
  - protects, as GMP models, only those that a valid modelsDesc of
    autoflowModelsLink lists under the stages 2DSA_IT, 2DSA_MC and PCSA
    (as a string equal to the model's ID, or an equal number), the same
    rule as UltraScan3's us_manage_data; models of other stages (2DSA,
    2DSA_FM, ...) are not protected.  That is policy, not an oversight:
    change it here and in UltraScan3 together.  A modelsDesc that is not
    valid JSON (a table created on MariaDB before 10.4.3 has no CHECK on
    the column) is not skipped, as UltraScan3 skips it, but protects the
    ID written after each "modelID" in its text, under any key: a
    deletion cannot be undone, and such a row still names GMP models.
    It no longer makes the call fail (it made JSON_CONTAINS raise error
    4038 on MariaDB, which stopped every edit deletion);
  - reads autoflowModelsLink once per call (autoflow_model_ids), so a
    call costs one pass over that table, not one per model and noise
    record: 0.2 s rather than 25-110 s for an edit with 1000 models and
    1000 noise records against 1000 links;
  - raises error 1213 (SQLSTATE 40001) instead of answering a status when
    a deadlock inside a caller's transaction made the server roll that
    whole transaction back (and likewise re-raises any other error after
    which its savepoint is gone);
  - uses the savepoint name us3_delete_editedData_sp.

As before, an administrator's call deletes, with the edit, the models
other investigators fitted to it and their noise, and anyone's call
deletes all noise fitted with the edit's models that it may delete, also
noise computed from another investigator's edit in another experiment
(a global fit).  The procedure's header lists exactly what goes.

create_buffer_component (us3_buffer_procs.sql) no longer reads the
highest ID with a locking read, which inside a caller's transaction held
a gap lock until it ended and deadlocked other connections creating
components.  It reads it without locking, and when the ID is taken tries
the next one, up to 100 times, before answering @INSERTDUP (402).  A
connection whose ID another transaction has inserted but not committed
waits for that transaction, as for any duplicate key.  So while a long
transaction that created a component is open -- UltraScan3's data import
holds one for the whole import -- every other connection creating a
component waits until it commits or rolls back, and fails with error
1205 after innodb_lock_wait_timeout (50 s by default).  There is no
deadlock, and the IDs stay distinct.  Only giving bufferComponentID an
AUTO_INCREMENT would remove that wait (AUTO_INCREMENT values are not
held to the end of the transaction); that is a schema change, left for
now.  The header of each procedure has the details;
tests/write_procs_test.sh checks them.


Telling an updated database from an old one (us3_catalog_version)

us3_procedures.sql creates the function us3_catalog_version(), which
answers the version of the procedures loaded:

  0  (no such function) procedures from before these changes;
  1  the catalog procedures, and create_buffer_component,
     delete_editedData and the autoflow inserts as described above;
  2  as 1, plus two new procedures (below); delete_editedData reads
     autoflowModelsLink once per call and copes with a row that is not
     valid JSON (above).  No parameter list changed.

A client asks with "SELECT us3_catalog_version()" and takes error 1305
(the function does not exist) or 1370 (no EXECUTE privilege on it) as 0.
UltraScan3's data import, for example, can then skip its warning that a
new buffer component may collide with an existing ID -- old
create_buffer_component gave a new row the row count plus one -- and use
the ID that last_insertID() reports after create_buffer_component, rather
than finding the new row by its definition.  On version 0 it must keep
doing both.

The file drops the function first and creates it last, so a load that
stops half-way leaves none behind.  The mysql client stops at the first
error, also in a sourced file; the mariadb client (10.11) reports an
error in a sourced file, goes on and exits 0, so with it the function
says only that the load ran to the end: check its output for errors.
Loading one of the sourced files on its own does not change it.  Raise
the number, in us3_procedures.sql and here, with every change to the
procedures a client may need to tell apart.

The marker can therefore be stale -- say 2 while the procedures are
older:

  - after a load with --force (mysql --force, or the mariadb client,
    which behaves so for sourced files): a file that failed leaves its
    old procedures in place, or none, and the marker is created anyway;
  - after loading an older copy of one of the sourced files on its own
    (say us3_expdata_procs.sql from before version 1): the marker still
    describes the last complete load of us3_procedures.sql;
  - after loading an older us3_procedures.sql over a newer one, the
    marker says the older version, but procedures that only the newer
    one has (clear_experiment_fields, say) are still there.

Load the whole of us3_procedures.sql, without --force, and check the
output for errors.  A client should still handle error 1305 for a
procedure it expects from the version.


Server versions

The procedures need MySQL 5.7.8 or later, or MariaDB 10.2.7 or later.
delete_editedData uses JSON_VALID, JSON_EXTRACT, JSON_LENGTH and
JSON_UNQUOTE, which came with MySQL 5.7.8 and MariaDB 10.2.3, and us3.sql
declares autoflowModelsLink.modelsDesc as JSON, a type MariaDB has from
10.2.7 (an alias for LONGTEXT; a CHECK ( JSON_VALID(...) ) since 10.4.3).
Nothing needs JSON_TABLE (MySQL 8.0.4, MariaDB 10.6).  The tests run on
MySQL 8.0.46 and MariaDB 10.11 (tests/README).


Upstream

These changes are on top of the two commits that added
us3_catalog_procs.sql to doluk/us3_sql ("Add per-experiment catalog
procedures" and "Add bulk catalog procedures that do not hash the data
blobs"), which ehb54/us3_sql does not have.  A pull request to
ehb54/us3_sql must carry those two commits as well as the ones after
them, or us3_procedures.sql sources a file that is not there.


New in version 2: clear_experiment_fields, set_rotor_calibration_date

No existing procedure's parameters changed (the LIMS calls them).  Two
procedures were added for clients that copy records from elsewhere --
UltraScan3's data import -- and must keep what update_experiment and
add_rotor_calibration cannot store:

  clear_experiment_fields( personGUID, password, experimentID,
                           clearProtocol, clearRIProfile )
    sets experiment.centrifugeProtocol and/or RIProfile to NULL
    (update_experiment stores '' for NULL).  Allowed to an administrator
    and to anyone with an experimentPerson row for the experiment
    (verify_catalog_experiment; experiment 1 gets no special treatment).
    Status 0, the login's codes, 201 or 508.

  set_rotor_calibration_date( personGUID, password, rotorCalibrationID,
                              dateUpdated )
    sets rotorCalibration.dateUpdated (add_rotor_calibration stores the
    time of the call), in the connection's time zone; NULL stores NULL.
    Administrators only, as add_rotor_calibration.  Status 0, the
    login's codes, 201, 519 (no such calibration), or -1 for a date
    outside the TIMESTAMP range.

A client calls them, inside its transaction, only when
us3_catalog_version() is 2 or more; otherwise it keeps the old behaviour
and says what it could not preserve.
