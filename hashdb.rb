# Hashdb - A ruby backup client

# This script is designed to let you create efficient diff-based backups of a computer. Before using this script, you should fully understand who should use it and why:

# DO NOT USE IT IF:
# You want to browse the destination filesystem in the same way you can browse the drive to be backed up (backed-up files will be stored by file hash, and not by original file name)
# You care about history, with the ability to restore the filesystem at specific times (use something like ZFS's snapshots)
# You care about the ability to plug in the backup and immediately use it like you would the source drive (booting, browsing, etc)
# You care about permissions / other filesystem metadata remaining intact.

# YOU SHOULD USE IT IF:
# You are storing large quantities of data backed up off-site, and want to minimize the amount of time those drives are back on-site to perform a backup.
# You only want the backup drives to be as large as the current working tree (e.g. 6TB of stuff should require buying only 6TB of backup drives), and don't want to store history.
# You want to see what files have changed between backups (and get notified in case something like a corrupt file has occurred on either the source or destination drives)
# IO is slow, and you want to minimize the amount of time each backup takes to perform
# You do not want to risk wiping an old backup drive to create a new backup (the old backup will be transformed into the new backup without ever deleting anything. Files that no longer exist on the source drive will be stored in a folder called /deprecated/, for you to manually sort through.
# You are backing things up from a variety of filesystems and sources, and can't rely on something like ZFS send/receive or macOS's Time Machine

# ------ 

# Modes of operation, and an explanation of what each thing does:
# Before running this script, move everything on backup drives into a /deprecated/ folder. This script will determine which files from previous backups are needed in the current backup, and will move those files back into /current/.

# ruby hashdb.rb scrub Old_Backup <-- creates an index of everything on this drive, storing <drive / path / hash>
# ruby hashdb.rb scrub Live <-- does the same thing to your stuff to be backed up
# ruby hashdb.rb scan Old_Backup <-- creates an index (like scrub), except doesn't actually read over every file. You can use this on old backups to generate faster diffs, if performed frequently
# ruby hashdb.rb migrate Old_Backup <-- if files exist on a backup drive from an old backup, this will move them into the /current/ folder, saving time on future data transfers
# ruby hashdb.rb mark Old_Backup <-- Goes through the records for the stuff to be backed up, and marks off what doesn't need to be copied, and which backup drive it's on
# ruby hashdb.rb fill Old_Backup <-- Starts copying the stuff that doesn't exist on your Old_Backup drive to your Old_Backup drive.
# ruby hashdb.rb receipt Old_Backup <-- dumps a copy of the DB into the root of Old_Backup. This is required to restore the backup, unless you want to pour over thousands of file hashes manually.

# NOTE: Before running this script, define the line below with the drive name of the thing to be backed up.
# Also change the drive path to something more appropriate if you aren't using macOS

source_drive = 'Koholint'
drive_path = '/Volumes/'

# Why it's better:
# 'scrubs' are slow. They involve reading the whole drive over. Since disk I/O is super slow relative to everything else we should do this a maximum of once per drive.
# In the case of a drive stored in a safe deposit box, we want to minimize the amount of time spent with the backup drive physically present. This means we should perform all operations that don't need the backup physically present before plugging it in onsite.
# Once everything has been scrubbed (a task that can run in parallel if you want), we want to minimize the number of writes and reads to every drive. We compute what's already on the backup drive (and should stay there), and compute what shouldn't be there (for you to prune over manually).
# We don't need to care about where files should go on backup drives. This is super useful if you have say, 12 x 1TB drives, and a 6TB folder called 'Photos'. Your photos will be distributed across backup drives to fill up as much space on each backup drive as possible.
# When files are renamed / moved / deleted on the source filesystem, we can generate a new file/folder structure (used when restoring a backup) within minutes (just given the current drive), rather than having to do things manually or create a new backup.

# An alternative to 'scrub' is 'scan'. This doesn't actually hash everything, but assumes that the files themselves will hash to whatever the filename is. You should alternate between scrub and scan as you want. ZFS recommends scrubbing once per month for most people,
# so a user performing a backup on a weekly basis probably doesn't need to scrub that often. If your drives are stored and accessed yearly, you probably shouldn't use scan.

require 'pg'
require 'active_record'
require 'digest'
require 'fileutils'

ActiveRecord::Base.establish_connection(
  "postgres://tyler@localhost/hashdb"
)

class Hashfile < ActiveRecord::Base
  self.table_name = "files"
end

mode = ARGV[0].downcase
drive = ARGV[1]

# A stupid hash function that's necessary to prevent IO errors if files are too big.
# tl;dr: only reads small amounts of files at a time, to prevent EINVAL / massive RAM usage.

def sha256(file)
  hash = File.open(file, 'rb') do |io|
    dig = Digest::SHA2.new(256)
    buf = ""
    dig.update(buf) while io.read(4096, buf)
    dig
  end
  return hash.hexdigest
end

# --- The actual program

if mode == "scrub" || mode == "scan"
  Dir.glob(drive_path + drive + "/**/*") do |file|
    if File.file?(file)
      begin
        if mode == "scrub"
          hash = sha256(file)
          puts "working on: #{file}... - #{hash}"
        elsif mode == "scan"
          hash = file.split(drive_path + drive)[1].gsub('/', '')
          puts "working on: #{file}"
        end
        path = file.split(drive_path + drive)[1]
        hashfile = Hashfile.where(path: path, checksum: hash, drive: drive).first
        if hashfile.nil?
          Hashfile.create(path: path, checksum: hash, drive: drive)
        end
      rescue IOError => e
        puts e
      end
    end
  end
  puts "All done #{mode}#{mode[-1]}ing #{drive}"
elsif mode == "migrate"
  # Determine what's on the backup drive that should stay on the backup drive
  Hashfile.where(drive: drive).find_each do |file|
    original = Hashfile.where(checksum: file.checksum, drive: source_drive).first
    #move file
    if original
      begin
        FileUtils.mkdir_p(drive_path + drive + "/current/#{file.checksum[0..1]}")
        FileUtils.mv(drive_path + drive + file.path, drive_path + drive + "/current/#{file.checksum[0..1]}/#{file.checksum[2..-1]}")
      rescue Exception => e
        puts e
      end
    else
      # Leave it alone in the current folder structure
    end
  end
elsif mode == "mark"
  Dir.glob(drive_path + drive + '/current/**/*') do |file|
    if File.file?(file)
      hash = file.split(drive_path + "#{drive}/current/")[1].gsub('/', '')
      original = Hashfile.where(checksum: hash, drive: source_drive).first
      if original
        original.update(backup_drive: drive)
      end
    end
  end
elsif mode == "fill"
  begin
    Signal.trap('USR1') { display_status(mode, source_drive, drive) }
    Signal.trap('INFO') { display_status(mode, source_drive, drive) } if Signal.list.include? 'INFO'

    Hashfile.where(drive: source_drive, backup_drive: nil).find_each do |file|
      FileUtils.cp(drive_path + source_drive + file.path, drive_path + drive + "/#{file.checksum}")
      FileUtils.mkdir_p(drive_path + drive + "/current/#{file.checksum[0..1]}")
      FileUtils.mv(drive_path + drive + "/#{file.checksum}", drive_path + drive + "/current/#{file.checksum[0..1]}/#{file.checksum[2..-1]}")
      file.update(backup_drive: drive)
    end
  rescue IOError => e
    # This is probably because we're out of space. We should probably handle it somehow, or otherwise do something about it.
    puts e
  end
elsif mode == "receipt"
  #Generate a nice text file that allows restoring the backup, to be stored on each backup drive.
  host = Hashfile.connection_config[:host]
  database = Hashfile.connection_config[:database]
  username = Hashfile.connection_config[:username]
  cmd = "pg_dump --host #{host} --username #{username} --verbose --clean --no-owner --no-acl --format=c #{database} > '#{drive_path + drive}/#{Time.now.year}-#{Time.now.month}-#{Time.now.day} hashdb.dump'"
  puts cmd
  exec cmd
elsif mode == "restorefs"
  #TODO: Unpack the backup into something resembling the source filesystem (as much as possible)
elsif mode == "restoredb"
  #TODO: restore the DB dump from a receipt
#elsif mode == ""
  #TODO: Unpack the stuff that's on the backup drive that shouldn't be there back into a proper directory structure
end

def display_status(mode, source_drive, drive)
  if mode == "fill"
    puts "#{Hashfile.where(drive: source_drive, backup_drive: nil).count} files remaining to be copied to #{drive}."
  end
end
