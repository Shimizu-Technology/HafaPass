#!/usr/bin/env ruby
# frozen_string_literal: true

# CPU and memory per Puma process (master, worker 0 with the Solid Queue supervisor, worker 1),
# plus the container's own cgroup totals on Linux. Needs no gems and no Rails: run it in the
# Render shell of the isolated copy while the load runs, and keep the output.
#
#   ruby script/rush_test/proc_sampler.rb            # 120 s, one sample every 2 s
#   SAMPLE_SECONDS=240 SAMPLE_INTERVAL=1 ruby script/rush_test/proc_sampler.rb
#
# Prints one CSV line per process per sample (so you can paste it into a sheet) and a summary
# with each process's peak CPU% (of one core) and peak RSS. Ctrl-C prints the summary early.
# Linux reads /proc and /sys/fs/cgroup (what the Render container has); macOS falls back to `ps`.
duration = Integer(ENV.fetch("SAMPLE_SECONDS", "120"))
interval = Float(ENV.fetch("SAMPLE_INTERVAL", "2"))
abort "SAMPLE_SECONDS must be 5..3600 and SAMPLE_INTERVAL 0.5..30" unless duration.between?(5, 3600) && interval.between?(0.5, 30)

LINUX = File.directory?("/proc/self")
CLK = LINUX ? (`getconf CLK_TCK`.to_i.nonzero? || 100) : 100

def puma_pids
  if LINUX
    Dir.children("/proc").grep(/\A\d+\z/).select do |pid|
      File.read("/proc/#{pid}/cmdline").tr("\0", " ").match?(/puma/i)
    rescue StandardError
      false
    end.map(&:to_i)
  else
    `ps -axo pid=,command=`.lines.select { |line| line.match?(/puma/i) && !line.include?("proc_sampler") }.map { |line| line.split.first.to_i }
  end
end

def role(pid, master)
  return "master" if pid == master

  "worker"
end

def cpu_ticks(pid)
  fields = File.read("/proc/#{pid}/stat").sub(/\A.*\) /, "").split
  fields[11].to_i + fields[12].to_i # utime + stime
end

def rss_kb(pid)
  if LINUX
    File.read("/proc/#{pid}/status")[/VmRSS:\s+(\d+)/, 1].to_i
  else
    `ps -o rss= -p #{pid}`.to_i
  end
end

def ppid(pid)
  LINUX ? File.read("/proc/#{pid}/stat").sub(/\A.*\) /, "").split[1].to_i : `ps -o ppid= -p #{pid}`.to_i
end

def cgroup_numbers
  return nil unless File.exist?("/sys/fs/cgroup/cpu.stat")

  usage = File.read("/sys/fs/cgroup/cpu.stat")[/usage_usec (\d+)/, 1].to_i
  current = File.read("/sys/fs/cgroup/memory.current").to_i
  max = File.read("/sys/fs/cgroup/memory.max").strip
  { usage_usec: usage, memory_current: current, memory_max: max == "max" ? nil : max.to_i }
rescue StandardError
  nil
end

peaks = Hash.new { |hash, key| hash[key] = { cpu: 0.0, rss_mb: 0.0 } }
previous = {}
stop = false
trap("INT") { stop = true }
trap("TERM") { stop = true }
puts "time_utc,pid,role,cpu_percent_of_one_core,rss_mb"
last_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
last_cgroup = cgroup_numbers
deadline = last_time + duration
cgroup_peak = { cpu_cores: 0.0, memory_mb: 0.0, memory_max_mb: nil }
until stop || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep interval
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  elapsed = now - last_time
  pids = puma_pids
  master = pids.find { |pid| !pids.include?(ppid(pid)) }
  stamp = Time.now.utc.strftime("%H:%M:%S")
  pids.sort.each do |pid|
    rss = rss_kb(pid) / 1024.0
    cpu = if LINUX
      ticks = cpu_ticks(pid)
      percent = previous[pid] ? ((ticks - previous[pid]) / CLK.to_f) / elapsed * 100.0 : 0.0
      previous[pid] = ticks
      percent
    else
      `ps -o pcpu= -p #{pid}`.to_f
    end
    name = role(pid, master)
    label = "#{name}-#{pid}"
    peaks[label][:cpu] = [peaks[label][:cpu], cpu].max
    peaks[label][:rss_mb] = [peaks[label][:rss_mb], rss].max
    puts format("%s,%d,%s,%.1f,%.0f", stamp, pid, name, cpu, rss)
  end
  cgroup = cgroup_numbers
  if cgroup && last_cgroup
    cores = (cgroup[:usage_usec] - last_cgroup[:usage_usec]) / 1_000_000.0 / elapsed
    cgroup_peak[:cpu_cores] = [cgroup_peak[:cpu_cores], cores].max
    cgroup_peak[:memory_mb] = [cgroup_peak[:memory_mb], cgroup[:memory_current] / 1048576.0].max
    cgroup_peak[:memory_max_mb] = cgroup[:memory_max] && (cgroup[:memory_max] / 1048576.0)
    puts format("%s,container,cgroup,%.1f,%.0f", stamp, cores * 100.0, cgroup[:memory_current] / 1048576.0)
  end
  last_cgroup = cgroup
  last_time = now
  $stdout.flush
end

puts "\nSummary (peaks)"
peaks.sort_by { |label, _| label }.each do |label, peak|
  puts format("  %-14s peak CPU %6.1f%% of one core, peak RSS %6.0f MB", label, peak[:cpu], peak[:rss_mb])
end
if cgroup_peak[:memory_mb].positive?
  limit = cgroup_peak[:memory_max_mb] ? format("%.0f MB", cgroup_peak[:memory_max_mb]) : "no limit reported"
  puts format("  container      peak CPU %.2f cores, peak memory %.0f MB (limit %s)", cgroup_peak[:cpu_cores], cgroup_peak[:memory_mb], limit)
end
