# HashDB - A ruby backup client

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


# If you've already used hashdb before:
  # ruby hashdb.rb restoredb Old_Backup <-- Unpack the old PostgreSQL DB used in the previous backup

  #   Rename the /current/ folder on each backup drive to /deprecated/

  # ruby hashdb.rb restorefs Old_Backup <-- Re-generates a normal folder structure from the hash-addressed files, using the old PostgreSQL DB

  #   At this point, you can throw away the old database. 
  #   DELETE FROM hashdb_files WHERE set = X; 
  #   If you're using the same DB, increment current_set by one now.

# On a fresh database:
  # ruby hashdb.rb scrub Live <-- creates an index of everything to be backed up, storing <drive / path / hash>

  # ruby hashdb.rb scrub Old_Backup <-- creates an index of everything already on the backup drive, storing <drive / path / hash>
  # OR
  # ruby hashdb.rb scan Old_Backup <-- creates an index (like scrub), except doesn't actually read over every file. You can use this on old backups to generate faster diffs, if performed frequently

  # ruby hashdb.rb migrate Old_Backup <-- if files exist on a backup drive from an old backup, this will move them into the /current/ folder, saving time on future data transfers

  #   Next, remove all existing rows in the database where the source drive is the backup drive.
  #   These are files that are no longer referenced on the source drive. You should now move /restorefs/
  #   off your external drives and go through those files.

  #   DELETE from hashdb_files WHERE set = X AND drive = 'ZFS/Dataset';

  # ruby hashdb.rb mark Old_Backup <-- Goes through the records for the stuff to be backed up, and marks off what doesn't need to be copied, and which backup drive it's on
  # ruby hashdb.rb fill Old_Backup <-- Starts copying the stuff that doesn't exist on your Old_Backup drive to your Old_Backup drive.
  # ruby hashdb.rb receipt Old_Backup <-- dumps a copy of the DB into the root of Old_Backup. This is required to restore the backup, unless you want to pour over thousands of file hashes manually.

# NOTE: Before running this script, define the line below with the drive name of the thing to be backed up.
# Also change the drive path to something more appropriate if you aren't using macOS

source_drive = 'Koholint'
source_drive_subfolders = ['/TV', '/Music']

drive_path = '/media/'

# If you have multiple backup sets (distinct copies of your data in multiple locations), you'll have to increment this number each time you do a backup.
# Otherwise, hashdb will assume that your files are already on /a/ backup drive, so it shouldn't copy them again.
current_set = 0

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
  "postgres://username:password@localhost/hashdb"
)

class Hashfile < ActiveRecord::Base
  self.table_name = "hashdb_files"
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

def sha512(file)
  hash = File.open(file, 'rb') do |io|
    dig = Digest::SHA2.new(512)
    buf = ""
    dig.update(buf) while io.read(4096, buf)
    dig
  end
  return hash.hexdigest
end

if (mode == "scrub" || mode == "scan") && drive != source_drive
  Dir.glob(drive_path + drive + "/**/*") do |file|
    if File.file?(file)
      begin
        path = file.split(drive_path + drive)[1]
        hashfile = Hashfile.where(path: path, drive: drive, set: current_set).first
        if hashfile.nil?
          if mode == "scrub"
            hash = sha512(file)
            puts "working on: #{file}... - #{hash}"
          elsif mode == "scan"
            hash = file.split(drive_path + drive)[1].gsub('/', '')
            puts "working on: #{file}"
          end
          Hashfile.create(path: path, sha512: hash, drive: drive, timestamp: Time.now, set: current_set)
        end
      rescue IOError => e
        puts e
      end
    end
  end
  puts "All done #{mode}#{mode[-1]}ing #{drive}"
elsif (mode == "scrub" || mode == "scan") && drive == source_drive
  source_drive_subfolders.each do |subfolder|
    Dir.glob(drive_path + drive + subfolder + "/**/*") do |file|
      # Ignore:
      next if file.end_with?('.DS_Store')
      next if file.include?('/Koholint/Music/Phone/')

      # Validations:
      puts "You should extract #{file}", :stdout if file.include?('.r01')
      puts "Do not store lrcat files - ZIP them or export an actual Lightroom backup", :stdout if (file.end_with?('.lrdata') || file.end_with?('.lrcat')) && File.directory?(file)

      if File.file?(file)
        begin
          path = file.split(drive_path + drive)[1]
          hashfile = Hashfile.where(path: path, drive: drive, set: current_set).first
          if hashfile.nil?
            if mode == "scrub"
              hash = sha512(file)
              puts "working on: #{file}... - #{hash}"
            elsif mode == "scan"
              hash = file.split(drive_path + drive)[1].gsub('/', '')
              puts "working on: #{file}"
            end
            Hashfile.create(path: path, sha512: hash, drive: drive, timestamp: Time.now, set: current_set)
          end
        rescue IOError => e
          puts e
        end
      end
    end
  end
  puts "All done #{mode}#{mode[-1]}ing #{drive}"
elsif mode == "migrate"
  # Determine what's on the backup drive that should stay on the backup drive
  Hashfile.where(drive: drive, set: current_set).find_each do |file|
    original = Hashfile.where(sha512: file.sha512, drive: source_drive, set: current_set).first
    #move file
    if original
      begin
        FileUtils.mkdir_p(drive_path + drive + "/current/#{file.sha512[0..1]}")
        FileUtils.mv(drive_path + drive + file.path, drive_path + drive + "/current/#{file.sha512[0..1]}/#{file.sha512[2..-1]}")
      rescue Exception => e
#        puts e
      end
    else
      # Leave it alone in the current folder structure
    end
  end
  puts "Done. Starting cleanup..."
  Dir[drive_path + drive + '/restorefs/' + '**/'].reverse_each { |d| Dir.rmdir d if Dir.entries(d).size == 2 }
  puts "Done cleanup."
elsif mode == "mark"
  Dir.glob(drive_path + drive + '/current/**/*') do |file|
    if File.file?(file)
      hash = file.split(drive_path + "#{drive}/current/")[1].gsub('/', '')
      Hashfile.where(sha512: hash, drive: source_drive, set: current_set).find_each do |file|
        file.update(backup_drive: drive)
      end
    end
  end
elsif mode == "fill"
  begin
    Signal.trap('USR1') { display_status(mode, source_drive, drive) }
    Signal.trap('INFO') { display_status(mode, source_drive, drive) } if Signal.list.include? 'INFO'

    Hashfile.where(drive: source_drive, backup_drive: nil, set: current_set).find_each do |file|
      #next if File.size?(drive_path + source_drive + file.path) > (1024 * 1024 * 200)
      begin
        FileUtils.cp(drive_path + source_drive + file.path, drive_path + drive + "/#{file.sha512}")
        FileUtils.mkdir_p(drive_path + drive + "/current/#{file.sha512[0..1]}")
        FileUtils.mv(drive_path + drive + "/#{file.sha512}", drive_path + drive + "/current/#{file.sha512[0..1]}/#{file.sha512[2..-1]}")
        file.update(backup_drive: drive)
      rescue IOError => e
        puts e
      rescue SystemCallError => e
        puts e
      end
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
  cmd = "pg_dump --host #{host} --username #{username} --table public.hashdb_files --verbose --clean --no-owner --no-acl --format=c #{database} > '#{drive_path + drive}/#{Time.now.strftime('%Y-%m-%d')} hashdb.dump'"
  puts cmd
  exec cmd
elsif mode == "restorefs"
  puts "Restoring files from #{drive_path}#{drive}/deprecated/ to #{drive_path}#{drive}/restorefs/"
  Dir.glob(drive_path + drive + '/deprecated/' + '**/*') do |filename|
    next if filename == '.' or filename == '..'
    next if File.directory?(filename)
    checksum = filename.split(drive_path + drive + '/deprecated/')[1].gsub('/', '')
    files = Hashfile.where(sha512: checksum, drive: source_drive, set: current_set)
    count = files.count
    files.each_with_index do |file, i|
      file = Hashfile.where(sha512: checksum, set: current_set).first
      dir = File.dirname(file.path)
      FileUtils.makedirs(drive_path + drive + "/restorefs/#{file.drive}#{dir}")
      #puts "Moving #{file.sha512} to #{drive_path + drive + "/restorefs/" + file.drive + file.path}"
      if i == (count - 1)
        FileUtils.mv (drive_path + drive + "/deprecated/#{file.sha512[0..1]}/#{file.sha512[2..-1]}"), (drive_path + drive + "/restorefs/#{file.drive}#{file.path}")
      else
        FileUtils.cp (drive_path + drive + "/deprecated/#{file.sha512[0..1]}/#{file.sha512[2..-1]}"), (drive_path + drive + "/restorefs/#{file.drive}#{file.path}")
      end
    end
  end
  puts "Done. Starting cleanup..."
  Dir[drive_path + drive + '/deprecated/' + '**/'].reverse_each { |d| Dir.rmdir d if Dir.entries(d).size == 2 }
  puts "Done cleanup."
elsif mode == "restoredb"
  #TODO: restore the DB dump from a receipt
#elsif mode == ""
  #TODO: Unpack the stuff that's on the backup drive that shouldn't be there back into a proper directory structure
end

def display_status(mode, source_drive, drive)
  if mode == "fill"
    puts "#{Hashfile.where(drive: source_drive, backup_drive: nil, set: current_set).count} files remaining to be copied to #{drive}."
  end
end
