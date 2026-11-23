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
