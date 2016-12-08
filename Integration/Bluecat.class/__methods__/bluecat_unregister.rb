#
# bluecat_unregister
#
# CloudForms Management Engine Automate Method
# 
# Remove an object identified by MAC address in a Bluecat IPAM
# Tested with Bluecat BAM (API 4.1.1). May not work with API 4.0.x.
# This method should be called during retirement

# Change history:
# 2016-01-28 Initial integration with CFME (mwelk)
# 2016-01-04 Test and rewrite. We need to delete the IP address and MAC individually. (mwelk)

require "json"
require "savon"
require "nokogiri" # XML parser library
require 'active_support/core_ext/hash/conversions' # Some conversion, here used for XML to hash

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
  $evm.log("info", "Retrying current state: [#{msg}]")
  $evm.root['ae_result'] = 'retry'
  $evm.root['ae_reason'] = msg.to_s
  $evm.root['ae_retry_interval'] = retry_interval
  exit MIQ_OK
end

def bam_login()
  # This methods opens a session to a Bluecat IPAM
  # The session cookie is made available as a global variable,
  # same with the savon client definition, to be used by other
  # methods.

  # Fetch values from the class definition in CFME
  ipam_net_protocol   = $evm.object['ipam_net_protocol']
  ipam_net_hostname   = $evm.object['ipam_net_hostname']
  ipam_net_port       = $evm.object['ipam_net_port']
  ipam_logon_username = $evm.object['ipam_logon_username']
  ipam_logon_password = $evm.object.decrypt('ipam_logon_password')
  ipam_timeout_read   = $evm.object['ipam_timeout_read']
  ipam_timeout_open   = $evm.object['ipam_timeout_open']
  @ipam_serverlist     = $evm.object['ipam_serverlist']
  @ipam_deploywait     = $evm.object['ipam_deploywait'].to_i 

  @ipam_configname    = $evm.object['ipam_configname']

  ipam_baseaddr       = "#{ipam_net_protocol}://#{ipam_net_hostname}:#{ipam_net_port}/Services/API"

  # Set up savon client
  @ipam_client = Savon::Client.new(
    wsdl:            "#{ipam_baseaddr}?wsdl",
    open_timeout:    ipam_timeout_open.to_i,
    read_timeout:    ipam_timeout_read.to_i,
    ssl_verify_mode: :none,
    log_level:       :debug
    )

  begin
    # Login to Bluecat IPAM
    log("debug", "Logging in to Bluecat at #{ipam_baseaddr}") 
    ipam_response = @ipam_client.call(:login,
      message: {
        username: ipam_logon_username,
        password: ipam_logon_password
      }
   ) 

    if ipam_response.http.code != 200
      log("info", "Bluecat IPAM login failed with HTTP return code #{ipam_response.http.code}")
      retry_method("Bluecat IPAM error, retrying")
    end
  rescue
    retry_method("Bluecat IPAM error, retrying")
  end
  @ipam_auth_cookies = ipam_response.http.cookies
end

def bam_delete_id(id)
  #puts "bam_delete id = #{id}"
  
  ipam_response = @ipam_client.call(:delete,
    cookies: @ipam_auth_cookies,
    message: {
      objectId: id.to_s
    }
    )
  
  if ipam_response.http.code.to_i == 200
    log("info", "Deleted object id #{id} from IPAM")
    return true
  else
    log("error", "Error deleting object id #{id} from IPAM, response = #{ipam_response.inspect}")
    return false
  end
end

def get_mac_address(macaddr)
  ipam_response = @ipam_client.call(:get_mac_address,
    cookies: @ipam_auth_cookies,
    message: {
      configuration_id: @ipam_configuration_id,
      mac_address: macaddr.to_s
    }
    )

  log("info", "Unregister Bluecat IPAM get_mac_address macaddr=#{macaddr}, response body=#{ipam_response.body.inspect}")
  
  if ipam_response.http.code.to_i == 200
    id = ipam_response.body[:get_mac_address_response][:return][:id]
    return id
  else
    log("error", "Error in Bluecat IPAM call search_by_category, keyword=#{keyword}, response body=#{ipam_response.body}")
    return ""
  end 
end

def bam_get_configuration_id()
  # Fetch the configuration ID from the Bluecat IPAM
  ipam_response = @ipam_client.call(:get_entity_by_name,
    cookies: @ipam_auth_cookies,
    message: {
      parent_id: 0,
      name:      @ipam_configname,
      type:      'Configuration'
    }
    )

  configuration_id = ipam_response.to_hash[:get_entity_by_name_response][:return][:id]
  log("debug", "Bluecat configuration_id = #{configuration_id}")
  return configuration_id
end

def bam_search_by_category(keyword, category)
  ipam_response = @ipam_client.call(:search_by_category,
    cookies: @ipam_auth_cookies,
    message: {
      keyword:  "#{keyword}",
      category: "ALL",
      start:    0,
      count:    1000000
      }
    )
  
  # If API call came back with an HTTP error code (all not 200), retry
  until ipam_response.http.code.to_i == 200
    log("error", "Error in Bluecat IPAM call search_by_category, keyword=#{keyword}, response body=#{ipam_response.body}")
    retry_method('Bluecat API response error, retry', retry_interval = 10)
  end
  
  log("info", "Bluecat IPAM call search_by_category, keyword=#{keyword}, response body=#{ipam_response.body}")
  
  # If we got a response, return it
  id = ipam_response.body[:search_by_category_response][:return][:item][:id] ||= ""
  until id == ""
    return id
  end

  # Otherwise, we got an empty response. This seems to happen occasionally. Retry.
  retry_method('Bluecat API response empty, retry', retry_interval = 10)
end

def bam_logout()
  # Logout from a Blueat session
  ipam_response = @ipam_client.call(:logout,
    cookies: @ipam_auth_cookies,
    )
  return ipam_response
end

#$evm.instantiate('/Utility/ObjectWalker/ObjectWalker')

vmname      = $evm.root['vm'].name.to_s
vmipaddress = $evm.root['vm'].custom_get('bluecat_ipaddress')

if vmipaddress.nil?
  log('info', "Virtual machine #{vm} has no extended attribute containing the IP address, trying to use address from vm record")
  vmipaddress = $evm.root['vm'].ipaddresses[0].to_s
  if vmipaddress.nil?
    log('error', "Virtual machine #{vm} cannot be removed from IPAM, no IP address known in CFME")
  end
end

vmmacadress = $evm.root['vm'].mac_addresses[0].to_s

# Login to IPAM already, and get required data for later requests,
# to reduce the time between name and IP reservation

log("info", "Unregistering from IPAM #{vmname} IP #{vmipaddress} MAC #{vmmacadress}")

bam_login

@ipam_configuration_id = bam_get_configuration_id()


vmmacid = get_mac_address(vmmacadress)

vmipid  = bam_search_by_category(vmipaddress, "IP4Address")

begin
  log("info", "Unregistering from IPAM #{vmname} IP #{vmipaddress} (id=#{vmipaddress}) MAC #{vmmacadress} (id=#{vmmacid}), configuration_id=#{@ipam_configuration_id}")

  bam_delete_id(vmmacid)
  bam_delete_id(vmipid)
rescue
  log("error", "Unregistering from IPAM #{vmname} IP #{vmipaddress} MAC #{vmmacadress} ended with error")
end

bam_logout

exit MIQ_OK
