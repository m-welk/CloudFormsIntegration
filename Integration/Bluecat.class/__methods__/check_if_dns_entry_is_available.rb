#
# check_dns_entry_is_available
#

require 'resolv'

def log(loglevel, logmsg)
  # Write a log message.
  # When running inside CFME, use their logging mechanism.
  # Otherwise, write it to stdout.
  if defined? $evm
    $evm.log(loglevel, "#{@method} #{logmsg}")
  else
    puts "#{logmsg}"
  end
end

def retry_method(msg, retry_interval = 60)
  log("info", "Retrying current state: [#{msg}]")
  $evm.root['ae_result'] = 'retry'
  $evm.root['ae_reason'] = msg.to_s
  $evm.root['ae_retry_interval'] = retry_interval
  exit MIQ_OK
end

begin
  # Get provisioning object
  @prov = $evm.root["miq_provision"]
  
  hostfqdn = @prov.get_option(:vm_fqdn)
  vmipaddr = @prov.get_option(:vmipaddr).to_s
  
  ipaddrs = Array.new
  Resolv::DNS.new.each_address(hostfqdn) { |addr| ipaddrs[ipaddrs.count] = addr }

  if ipaddrs.count.to_i == 0
    log("info", "check_dns_entry_is_available - IP address of #{hostfqdn} cannot be resolved yet from DNS")
    retry_method("Waiting for DNS (IPAM - Bluecat Deployment)")
  elsif ipaddrs.count.to_i == 1
    if ipaddrs[0].to_s == vmipaddr
      log("info", "check_dns_entry_is_available -  IP adress of #{hostfqdn} resolves to #{ipaddrs[0]}, correct")
      exit MIQ_OK
    else
      log("error", "check_dns_entry_is_available - probably DNS inconsistency, #{hostfqdn} resolved to #{ipaddrs[0]}, aborting")
      exit MIQ_ABORT
    end
  else
    log("error", "check_dns_entry_is_available - Something unexpected happened, multiple responses from DNS for #{hostfqdn} - #{ipaddrs[0]}")
    exit MIQ_ABORT
  end
end

log("error", "This should never be reached")
exit MIQ_ABORT
