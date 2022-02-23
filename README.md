# HashDB - A ruby backup client

HashDB is a backup client written in Ruby for people dealing with specific types of files in specific use cases. Typical backup systems do not handle these files well and can lead to silent data loss, so HashDB is a way to prevent that from happening.

A good example use case is a photographer who takes lots of photos, and does not ever want them to change on disk. They might move the files around, by renaming them or organizing them differently, but the files themselves should never change. ZFS snapshots will store the old blocks on disk if they're ever changed, but snapshots are often pruned over time as more and more blocks are rewritten and free space is reclaimed. This also applies to a strategy like `chmod 555` - ultimately it might prevent accidental deletion, but the onus is on you to notice that things are missing or altered and to restore them in time. Both of these strategies are useful for businesses (where errors are likely to be caught immediately), but terrible for home users, where old files might go years without being opened and nobody is going to notice that they accidentally nuked some childhood memories. Even making backups religiously isn't a solution here, as you might not notice that files were accidentally deleted before having rotated out all old backups.

HashDB works by computing checksums of every file, and then copies them to a backup drive. Later on, when a subsequent backup is run, it computes what's already on the backup, what is on the backup that should no longer be there, and what has to be transferred to the backup to bring it up to date. This gives you the opportunity to see exactly what changed, and either restore it from backup, or choose to overwrite it if the deletion/modification was intentional. Effectively, you have to explicitly sign off multiple times on any changes, which gives you ample opportunity to question what those changes are.

Other design goals of this software include:
* Making it simple to understand and debug (backups are not backups if they aren't tested), and a database is used so that we can graphically see what's in it easily
* Minimizing the amount of time that drives are on-site, if they're normally stored off-site
* Minimizing the amount of external storage involved - nTB of files should only take nTB to store
* Minimizing I/O, so files that are already in a backup and belong in a new backup aren't rewritten
* Ensuring that old backups are never corrupted while transforming them into new backups
* Supporting almost every reasonable destination filesystem

HashDB does not:
* Support encryption or compression - you should use an underlying filesystem for your backups that supports these things, like ZFS
* Attempt to repair damaged files - this requires additional disk space or drives, and you are better off just having more backups
* Let you easily browse a backup filesystem (files are stored by hash and not by name - you cannot boot off of a backup)
* Store history or metadata - only the file contents at the time of the backup are stored

HashDB is designed to have minimal dependencies, so it can be easily modified to run on anything. This is because files are often stored on a NAS, which might only have a 1 Gbps ethernet connection, and the backup drives might be connected over USB 3.0 (5+ Gbps). It is better to be able to run this software on the NAS itself (and not transfer every file first over Samba). However, you might want to see what changed sitting at your local computer, so we also have to support plugging in drives locally and running a restore script. Also, if someone else has to recover files on your behalf, esoteric programs that only run on specific hardware and OS combinations aren't good. HashDB uses ActiveRecord, which connects to PostgreSQL (because I prefer it), but it can be easily swapped for SQLite or another database engine. No RDBMS-specific queries are used. 

Specific usage instructions are included inline with the code itself.

## TODO:

* Store permissions and metadata, so that things like creation date can be restored
* Parallel filling, so three empty backup drives will fill up at the same time instead of waiting for one to finish before the next one can start
* Smarter filling, so a 2TB drive isn't considered filled if a 3TB file won't fit on it (files are copied in alphabetical order)
