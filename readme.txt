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
tests/catalog_smoke.sh checks them against a scratch database; see
tests/README.


delete_editedData (changed behaviour)

delete_editedData (us3_expdata_procs.sql):

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
    change it here and in UltraScan3 together.  A stage whose value is
    an object rather than an array ({"PCSA":{"modelID":"9405"}})
    protects nothing, as UltraScan3 reads only arrays: a GMP writer must
    store arrays.  A number that a double cannot hold, such as 1e400
    (valid JSON on MariaDB), names no model.  A modelsDesc that is not
    valid JSON (a table created on MariaDB before 10.4.3 has no CHECK on
    the column) is not skipped, as UltraScan3 skips it, but protects the
    ID written after each "modelID" in its text, under any key: a
    deletion cannot be undone, and such a row still names GMP models.
    Two limits of that text rule: the ID must be written as it is (a
    leading zero, as in "modelID":"09405", names no model), and it must
    start within 8 characters after "modelID" (wider separators are not
    read);
  - reads autoflowModelsLink once per call, after it has locked the
    edit's models and noise, with a shared-locking read, so that a GMP
    link committed while it waited for one of those locks is seen, also
    inside a caller's transaction whose snapshot is older.  It looks
    each model ID a link names up in the short list of the models in
    question, so a call costs one pass over that table, linear in its
    size: about 0.3 s for an edit with 1000 models and 1000 noise
    records against 1000 links, and 0.5-0.7 s for an edit with a few
    models against 20000 links of 9 models each (it takes a link's IDs
    one by one only when their text may hold one of the edit's model
    IDs).  For an edit with no models and no noise it does not read the
    table at all;
  - holds, until its transaction ends -- inside a caller's transaction,
    until the caller commits or rolls back -- shared locks on every row
    of autoflowModelsLink and, under REPEATABLE READ, on the gaps
    between them, so that meanwhile a GMP writer that inserts, changes
    or deletes a link waits for it (and fails with error 1205 after
    innodb_lock_wait_timeout).  Under REPEATABLE READ it also locks the
    gaps next to the edit's entries in the editedDataID indexes of model
    and noise: a model or noise record inserted meanwhile for an edit
    whose ID falls in such a gap waits too -- when the edit has the
    highest ID that has models, a new fit of any newer edit;
  - deletes only the models and noise records it checked: under READ
    COMMITTED, which takes no gap locks, one that another connection
    commits against the edit after the checks stays, the edit's own
    delete fails on its foreign key, and the call answers
    @CONSTRAINT_FAILED (404), deleting nothing;
  - raises error 1213 (SQLSTATE 40001) instead of answering a status when
    a deadlock inside a caller's transaction made the server roll that
    whole transaction back (and likewise re-raises any other error after
    which its savepoint is gone).  It locks an edit's models before
    their noise, while delete_model, and UltraScan3 when it removes a
    model (delete_noise, then delete_model), take the noise first: the
    two can deadlock on the same records, and the server then rolls one
    of them back (1213); either may be repeated;
  - uses the savepoint name us3_delete_editedData_sp.

As before, an administrator's call deletes, with the edit, the models
other investigators fitted to it and their noise, and anyone's call
deletes all noise fitted with the edit's models that it may delete, also
noise computed from another investigator's edit in another experiment
(a global fit).  The procedure's header lists exactly what goes.


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
