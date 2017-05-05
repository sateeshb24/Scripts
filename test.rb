#!/usr/bin/env ruby

require 'optparse'
require 'open3'
require 'aws-sdk'
require 'yaml'

#-------------------------------------------#
# Main Test deploy script
#
# Meant to deploy everything to a particular env by calling the alls for each stack
#
#-------------------------------------------

FAILED = 'failed'
SUCCESS = 'success'
KILLED = 'killed'

# Types of supported installs
CMD_ALL = 'all'
CMD_JUST_SERVERS = 'justServers'
CMD_ARRAY = [CMD_JUST_SERVERS]

@isRunning = true
@mutex = Mutex.new
@waitThread = nil
@threads = []
@logs = {}

#-------------------------------------------
# Trap ^C
#-------------------------------------------
Signal.trap("INT") {
  shutdown
}

#-------------------------------------------
# Trap `Kill `
#-------------------------------------------
Signal.trap("TERM") {
  shutdown
}

#-------------------------------------------
# Tear it all down
#-------------------------------------------
def shutdown()
  @mutex.synchronize do
    @isRunning = false
  end
  if !@waitThread.nil?
    Thread.kill(@waitThread)
  end
  @threads.each do |t|
    Thread.kill(t)
  end
  @logs.each do |k, v|
    v.close
  end
  exit
end

def readCmdLine(options)
  parser = OptionParser.new do |opts|

    opts.on('-e', '--env env', "Environment - #{TestDeploy::VALID_ENVS}") do |env|
      options[:env] = env;
    end

    opts.on('-r', '--region region', 'AWS region') do |region|
      options[:region] = region;
    end

    opts.on('-l', '--alternateregion alternateregion', 'AWS alternate region') do |alternateregion|
      options[:alternateregion] = alternateregion;
    end

    opts.on('-p', '--profile profile', "Profile - #{TestDeployProperties::VALID_PROFILES} ") do |profile|
      options[:profile] = profile;
    end

    opts.on('-c', '--changeprops changeprops', "Change property key/values (key1/value1,key2/value2,..)") do |changeprops|
      options[:changeprops] = validateParametersAndConvert(changeprops);
    end

    opts.on('-a', '--awsprofile awsprofile', "AWSProfile - #{TestDeployProperties::VALID_AWS_PROFILES} ") do |awsprofile|
      options[:awsprofile] = awsprofile;
    end

    opts.on('-d', '--deploy deployment', "Deployments - #{TestDeploy::VALID_DEPLOYMENTS} ") do |deployment|
      options[:deploy] = deployment;
    end

    opts.on('-v', '--version version', "Use the latest versions from s3 with this version '-v 16.7'") do |version|
      if version.include?('/')
        options[:version] = version.split('/').last
      else
        options[:version] = version
      end
    end

    opts.on('-u', '--useDefaults useDefaults', "a list of deployemnts to use from deployment_versions, only used if -v is specified ") do |version|
      options[:useDefaults] = version;
    end

    opts.on('-x', "Disables spinning curosr") do
      options[:spinningCursor] = nil;
    end

    opts.on('--dir dir', "specifying dir for logs") do |dir|
      options[:dir] = dir;
    end

    opts.on('-s', "( true / false ) show me but do nothing, note version must be specified") do |showMe|
      if showMe != true and showMe != false
        puts "-s must be either true / false : option #{showMe} is not valid"
        exit
      end
      options[:showMe] = showMe;
    end

    opts.on('--cmd cmd', "the command to execute may be one of  #{CMD_ARRAY}") do |cmd|
      if !CMD_ARRAY.include? cmd
        puts "--cmd must be one of #{CMD_ARRAY} option #{cmd} is not valid"
        exit
      end
      options[:command] = cmd;
    end

    opts.on('-h', '--help', 'Displays Help') do
      puts opts
      exit
    end
  end

  parser.parse!
end

#-------------------------------------------#
# Execute the deployment
#-------------------------------------------
def executeAll(options, result, effectiveVersions, spinningCursor, resultsDirectory)

  currentDir = File.expand_path(File.dirname(__FILE__))
  resultsDir = File.expand_path(Dir.home + "/.deploy")
  if !resultsDirectory.nil?
    resultsDir = resultsDirectory
  end
  Dir.mkdir(resultsDir) unless File.exists?(resultsDir)
  exeFile = File.expand_path("#{currentDir}/dr/deploy_Test_dr.rb")
  @logs['Testing'] = File.open(File.expand_path("#{resultsDir}/Common.log"), 'w')
  @logs[SUCCESS] = File.open(File.expand_path("#{resultsDir}/Success.log"), 'w')
  @logs[FAILED] = File.open(File.expand_path("#{resultsDir}/Failure.log"), 'w')
  @logs.each { |k, v| File.truncate(v, 0) }

  # Write the versions
  if options[:showMe] == false
    puts "Modifying file #{currentDir}/../enterpriseApplication/Test/properties/deployment_versions.yml"

    File.open("#{currentDir}/../enterpriseApplication/Test/properties/deployment_versions.yml", "w") do |file|
      file.write "versions:\n"
      effectiveVersions.each do |k, v|
        file.write "  #{k}: #{v}\n"
        puts "\t#{k}: #{v}"
      end
    end
  end

  # can't pass these custom option on
  command = options[:command]
  showMe = options[:showMe]

  # clear the options
  options.delete(:version)
  options.delete(:useDefaults)
  options.delete(:spinningCursor)
  options.delete(:dir)
  options.delete(:showMe)
  options.delete(:command)
  optionsStr = ''
  options.each { |k, v| optionsStr += " --#{k} \"#{v}\"" }
  exeCommand = exeFile + optionsStr
  starttime = Time.now
  proc_array = nil
  if command == CMD_JUST_SERVERS
    if showMe
      proc_array = [
          Proc.new { executeChildProcess(exeCommand + ' -n 10.4', options[:env], 'Test', starttime, result) }
      ]
    else
      proc_array = [
          Proc.new { executeChildProcess(exeCommand + ' -n 11.4', options[:env], 'Test', starttime, result) }
      ]
    end
  else
    puts "unsupported command #{command}"
    exit
  end
  runProcsMultiThreaded("Executing #{exeFile}", starttime, result, proc_array, spinningCursor)
end

#-------------------------------------------
# Spinning cursor && check for running processes
#-------------------------------------------
def show_wait_cursor(result, spinningCursor)
  chars = %w[| / - \\]
  fps = 10
  seconds = 99999999
  delay = 1.0/fps
  killed = []
  (seconds*fps).round.times { |i|
    if !spinningCursor.nil?
      @mutex.synchronize do
        print chars[i % chars.length]
      end
    end

    sleep delay

    @mutex.synchronize do
      if !spinningCursor.nil?
        print "\b"
      end
      if !@isRunning
        break
      end
    end
    if i > 0 && i % 100 == 0
      out = `ps -ef | grep ruby`
      @mutex.synchronize do
        @logs.each do |k, v|
          if !out.include? k and !killed.include? k
            puts '####################################'
            puts '#'
            puts "# #{k} Ended"
            puts "# For details see : #{v.path}"
            puts '#'
            puts '####################################'
            result[KILLED] << v.path
            killed << k
          end
        end
      end
    end
  }
end

#-------------------------------------------#
# Child process
#-------------------------------------------
def executeChildProcess(cmd, env, shard, starttime, result)

  @mutex.synchronize do
    puts "Executing Command : #{cmd}"
    puts "Detailed logs are available here : #{@logs[shard].path}"
  end

  Open3.popen2e(cmd) do |stdin, stdout_err, wait_thr|
    while line = stdout_err.gets do
      printLine(env, shard, line, starttime, result)
      $stdout.flush
      @mutex.synchronize do
        if !@isRunning
          break
        end
      end
    end
    exit_status = wait_thr.value
    unless exit_status.success?
      abort "FAILED !!! #{cmd}"
    end
  end
end


#-------------------------------------------
# std out + filtering
#-------------------------------------------
def printLine(env, shard, line, starttime, result)

  # write to the correct log
  @mutex.synchronize do
    @logs[shard].puts line
  end

  if line.include? 'ROLLBACK_IN_PROGRESS' or
      line.include? 'ROLLBACK_COMPLETE' or
      line.include? 'UPDATE_ROLLBACK_COMPLETE' or
      line.include? 'UPDATE_ROLLBACK_IN_PROGRESS'
    @mutex.synchronize do
      stackName = line[/^Stack [^ ]*/]
      if !result[FAILED].include? stackName
        result[FAILED] << stackName
      end
      endtime = Time.now
      time = "#{'%.2f' % ((endtime - starttime)/60)} min"
      puts "[ #{time} ] #{env} #{shard} : #{line}"
    end
  elsif line.include? 'UPDATE_COMPLETE' or
      line.include? 'CREATE_COMPLETE'
    @mutex.synchronize do
      stackName = line[/^Stack [^ ]*/]
      if !result[SUCCESS].include? stackName
        result[SUCCESS] << stackName
      end
      endtime = Time.now
      time = "#{'%.2f' % ((endtime - starttime)/60)} min"
      puts "[ #{time} ] #{env} #{shard} : #{line}"
    end
  elsif line.include? 'CREATE_IN_PROGRESS' or
      line.include? 'UPDATE_IN_PROGRESS'
    @mutex.synchronize do
      endtime = Time.now
      time = "#{'%.2f' % ((endtime - starttime)/60)} min"
      puts "[ #{time} ] #{env} #{shard} : #{line}"
    end
  end
end

#-------------------------------------------
# proc that does the execution
#-------------------------------------------
def runProcsMultiThreaded(title, starttime, result, proc_array, spinningCursor)

  puts '####################################'
  puts title
  puts '####################################'

  proc_array.each { |proc|
    @threads << Thread.new { proc.call }
  }

  @waitThread = Thread.new { Proc.new { show_wait_cursor(result, spinningCursor) }.call }

  #Block till all threads complete
  @threads.each { |thr| thr.join }

  Thread.kill(@waitThread)

  endtime = Time.now
  puts "\n####################################"
  puts "#{title} complete"
  puts "Elapsed time: #{'%.2f' % (endtime - starttime)} secs - #{'%.2f' % ((endtime - starttime)/60)} min"
  puts '####################################'

end

#-------------------------------------------
# get S3
#-------------------------------------------
def getS3(profile = 'Testdemo', region = 'us-west-1')
  ret = nil
  begin
    ret = Aws::S3::Client.new(
        :profile => profile,
        :region => region)
  rescue Exception => e
    puts "getS3(#{profile}, #{region}): error " + e.message
  end
  ret
end


#-------------------------------------------
# Returns the latest version
#-------------------------------------------
def getLatestVersion(id, matchVersion, s3)
  version = nil
  begin
    result = s3.list_objects(bucket: 'Test-testing-qa', prefix: "application/Test/#{id}/#{matchVersion}")
    if !result.nil?
      latest = nil
      result.data[:contents].each do |content|
        lastMod = content[:last_modified]
        if latest.nil? or lastMod > latest
          latest = lastMod
          version = content[:key].split('/')[-2]
        end
      end
    end

  rescue Exception => e
    puts "getLatestVersions(#{id}, #{matchVersion}): error " + e.message
  end
  version
end

#-------------------------------------------
# Returns the latest version
#-------------------------------------------
def getLatestVersions(matchVersion)
  ret = {}
  keyMap = {
      'Test_services' => 'server-Test-services-deployment',
      'Test_api' => 'server-Test-apis-deployment',
      'Test_mysql_proxy' => 'Test-mysql-proxy'}

  s3 = getS3()
  keyMap.each do |deployment, key|
    ret[deployment] = getLatestVersion(key, matchVersion, s3)
  end
  ret
end

#-------------------------------------------
# main
#-------------------------------------------
options = {:region => 'us-west-2', :profile => 'medium', :awsprofile => 'Testdemo',
           :version => nil, :useDefaults => nil, :spinningCursor => 'true', :dir => nil, :showMe => false, :command => CMD_JUST_SERVERS}

readCmdLine(options)

currentDir = File.expand_path(File.dirname(__FILE__))
# get the default versions
depV = YAML.load_file(File.expand_path("#{currentDir}/../enterpriseApplication/Test/properties/deployment_versions.yml"))
depV = depV['versions']

# the effective versions are the ones to be installed
effectiveVersions = depV

# The user has specified a version like 16.8.0
if !options[:version].nil?
  versions = getLatestVersions(options[:version])
  effectiveVersions = versions
  puts ''
  puts 'The versions found in S3 that are not the same as in deployment_versions.yml:'
  depV.each do |name, value|
    if versions[name] != value
      puts "\t#{name}: #{versions[name]} != #{value}"
    end
  end
  puts '' ''

  if !options[:useDefaults].nil?
    defaults = options[:useDefaults].split(',')
    puts 'The user opted to use these versions from deployment_versions.yml'
    defaults.each do |default|
      puts "\t#{default}: #{depV[default]}"
      effectiveVersions[default] = depV[default]
    end
    puts ''
  end
end

puts 'Based on the above the following versions will be deployed:'
effectiveVersions.each do |name, value|
  puts "\t#{name} = #{value}"
end

result = {SUCCESS => [], FAILED => [], KILLED => []}
executeAll(options, result, effectiveVersions, options[:spinningCursor], options[:dir])

puts '/n/n'
puts '####################################'
puts '# SUCCESSES '
result[SUCCESS].each do |success|
  puts "\t#{success}"
end
@logs[SUCCESS].puts result[SUCCESS]

puts '####################################'
puts '# FAILURES '
result[FAILED].each do |failed|
  puts "\t#{failed}"
end
@logs[FAILED].puts result[FAILED]

puts '####################################'
puts '# KILLED PROCESSES '
result[KILLED].each do |killed|
  puts "\t#{killed}"
end

shutdown
