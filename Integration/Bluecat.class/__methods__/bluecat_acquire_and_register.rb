#
# bluecat_acquire_and_register
#
# CloudForms Management Engine Automate Method
# 
# Acquire and register a host in a Bluecat IPAM
# Tested with Bluecat BAM (API 4.1.1). May not work with API 4.0.x.
# This method should be called twice during provisioning,
# first very early to reserve and register the address in IPAM,
# later on, to register the correct DHCP address.

# Change history:
# 2016-01-28 Initial integration with CFME (mwelk)

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
    log_level:       :error
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

def bam_get_defaultview_id()
  # Retrieve the configuration information for the network from Bluecat
  #baseaddr, cidrbits = networkdata[:networkaddress].split(/\//)
  #puts "baseaddr = #{baseaddr}"

  ipam_response = @ipam_client.call(:get_ip_ranged_by_ip,
    cookies: @ipam_auth_cookies,
    message: {
      type: 'IP4Network',
      address: @baseaddr,
      container_id: @ipam_configuration_id,
    }
  )

  @network = ipam_response.to_hash[:get_ip_ranged_by_ip_response][:return]

  networkproperties = Hash.new
  p=@network[:properties].split(/\|/)
  for q in p do
    key, value = q.split(/\=/)
    networkproperties[key] = value
  end

  defaultview_id = networkproperties["defaultView"]
  log("debug", "Bluecat defaultview_id = #{defaultview_id}")
  return defaultview_id
end

def bam_assign_next_free_ip()
  # Assign the next free IP address in the target network

  log("info", "bam_assign_ip4_address values: @ipam_configuration_id = #{@ipam_configuration_id}, @vmmacaddress = #{@vmmacaddress}, parent_id = #{@network[:id]}, @hostfqdn = #{@hostfqdn}, @ipam_defaultview_id = #{@ipam_defaultview_id}")

  ipam_response = @ipam_client.call(:assign_next_available_ip4_address,
    #:assign_ip4_address,
    cookies: @ipam_auth_cookies,
    message: {
      configuration_id: @ipam_configuration_id,
      mac_address:      @vmmacaddress,
      parent_id:        @network[:id],
      host_info:        "#{@hostfqdn},#{@ipam_defaultview_id},true,false",
      action:           'MAKE_DHCP_RESERVED',
      properties:       'contact=Auto-generated from CloudForms'
    }

  )

  puts "ipam_response = #{ipam_response.inspect}"
  id = ipam_response.body[:assign_next_available_ip4_address_response][:return][:id]
  puts "id = #{id}"

  properties = ipam_response.body[:assign_next_available_ip4_address_response][:return][:properties]
  #puts "properties = #{properties}"

  propertieshash = Hash.new
  p=properties.split(/\|/)
  for q in p do
    key, value = q.split(/\=/)
    propertieshash[key] = value
  end

  #puts "propertieshash = #{propertieshash.inspect}"

  #puts propertieshash["address"]

  return propertieshash["address"], id
end

def bam_assign_ip4_address(ip4_address)
  # Assign an IP address in the target network
  ipam_response = @ipam_client.call(:assign_ip4_address,
    cookies: @ipam_auth_cookies,
    message: {
      configuration_id: @ipam_configuration_id,
      ip4_address:      ip4_address,
      mac_address:      @vmmacaddress,
      host_info:        "#{@hostfqdn},#{@ipam_defaultview_id},true,false",
      action:           'MAKE_DHCP_RESERVED',
      properties:       'contact=Auto-generated from CloudForms'
    }

  )

  #log("info", "ipam_response = #{ipam_response.inspect}")
  returnvalue = ipam_response.body[:assign_ip4_address_response][:return]
  puts "returnvalue = #{returnvalue}"
end

def bam_get_mac_address()
  ipam_response = @ipam_client.call(:get_mac_address,
    cookies: @ipam_auth_cookies,
    message: {
      configuration_id: @ipam_configuration_id,
      mac_address: @vmmacaddress
      }
    )
    puts "get_mac_address = #{ipam_response.inspect}"
    id = ipam_response.body[:get_mac_address_response][:return][:id]
    puts "id = #{id}"
    return id
end

def bam_get_mac_address_entity()
  ipam_response = @ipam_client.call(:get_mac_address,
    cookies: @ipam_auth_cookies,
    message: {
      configuration_id: @ipam_configuration_id,
      mac_address: @vmmacaddress
      }
    )
    puts "get_mac_address = #{ipam_response.inspect}"
    entity = ipam_response.body[:get_mac_address_response][:return]
    puts "entity = #{entity.inspect}"
    return entity
end

def bam_delete(id)
  puts "bam_delete id = #{id}"
  
  ipam_response = @ipam_client.call(:delete,
    cookies: @ipam_auth_cookies,
    message: {
      objectId: id
      }
    )
    puts "bam_delete = #{ipam_response.inspect}"
end

def bam_delete_device_instance()
  puts "bam_delete_device_instance id = #{@vmmacaddress}"
  
  ipam_response = @ipam_client.call(:delete_device_instance,
    cookies: @ipam_auth_cookies,
    message: {
      configName: "#{@ipam_configname}",
      identifier: "#{@vmmacaddress}",
      options:    nil
      }
    )

  puts "bam_delete_device_instance = #{ipam_response.inspect}"
end

def bam_logout()
  # Logout from a Blueat session
  ipam_response = @ipam_client.call(:logout,
    cookies: @ipam_auth_cookies,
  )
  return ipam_response
end

def bam_deploy(id)
  log("info", "Calling Bluecat IPAM with deploy_server call on server id = #{id}")
  
  ipam_response = @ipam_client.call(:deploy_server,
    cookies: @ipam_auth_cookies,
    message: {
      serverId: id.to_s
      }
    )

  if ipam_response.http.code.to_i == 200
    return true
  else
    log("error", "Error from Bluetcat IPAM when calling deploy_server, response = #{ipam_response.inspect}")
    return false
  end
end

def bam_get_next_hostname()
   # This method looks for all host names registered in IPAM matching
   # cf followed by six digits, and gives back the last one.

   ipam_response = @ipam_client.call(:search_by_category,
    cookies: @ipam_auth_cookies,
    message: {
      keyword: "^cf*",
      category: "ALL",
      start: 0,
      count: 100000
      }
    )
    items = ipam_response.body[:search_by_category_response][:return][:item]
    #puts items.inspect

    names = Array.new
    names[0] = "cf000000"
    if items.nil?
      log("info", "It looks like we got an empty response to your question")
    else      
      items.each do |item|
        #puts item[:name]
        if item[:name] =~ /^cf[0-9][0-9][0-9][0-9][0-9][0-9]$/
          names << item[:name]
        end
      end
    end

    vms = $evm.vmdb('vm').all
    vms.each do |v|
      if v.name.match(/^cf[0-9]{6,}$/i)
       names << v.name
      end
    end

    nextname = names.sort.uniq.last.succ
    
    log("info", "Automatically generated hostname is #{nextname}")

    return nextname
end

def acquire_ip_address()
  # This method makes a reservation for an IP address

  # Create a random temporary MAC address
  @vmmacaddress = (1..6).map{"%0.2X"%rand(256)}.join("-")

  vm_name_from_servicedialog = @prov.get_option(:vm_hostname)
  log("info", "vm_name_from_servicedialog = #{vm_name_from_servicedialog}")

  if vm_name_from_servicedialog.nil?
    # Otherwise use whatever is in the vm_target_name
    vm_target_name = @prov.get_option(:vm_target_name)
  else
   # If a name is set in the service dialog, it has first priority
    vm_target_name = vm_name_from_servicedialog 
  end

  log("info", "vm_target_name = #{vm_target_name}")
  if vm_target_name =~ /^auto/
  # If it matches "auto", choose name automatically
    vm_target_name = bam_get_next_hostname
    log("info", "Using automatically generated VM name = #{vm_target_name}")
  else
    # Looks if the hostname is available.
    ipam_response = @ipam_client.call(:search_by_category,
      cookies: @ipam_auth_cookies,
      message: {
        keyword:  "^#{vm_target_name}.*",
        category: "ALL",
        start:    0,
        count:    10
      }
    )
    log("info", "ipam_response.inspect = #{ipam_response.inspect}")

    begin
      items = ipam_response.body[:search_by_category_response][:return][:item]
      log("info", "items = #{items}")
      if items.count >= 1
        log("error", "VM name #{vm_target_name} appears to be in use, giving up")
        exit MIQ_ABORT
      end
    rescue
      log("info", "ipam_response empty, assume there were no matching names found")
    end
  end

  @prov.set_option(:vm_target_hostname, vm_target_name.to_s)
  @prov.set_option(:vm_target_name,     vm_target_name.to_s)
  @prov.set_option(:vm_hostname,        vm_target_name.to_s)
  @prov.set_option(:vm_name,            vm_target_name.to_s)

  @hostfqdn = "#{vm_target_name}.#{@dnsdomain}"
  @prov.set_option(:vm_fqdn, @hostfqdn.to_s)
  log("info", "hostfqdn = #{@hostfqdn} hostfqdn.inspect #{@hostfqdn.inspect}")

  vmipaddress, ipam_vmid = bam_assign_next_free_ip
  @prov.set_option(:ipam_vmid, ipam_vmid.to_s)
  @prov.set_option(:vmipaddr,  vmipaddress.to_s)

  log("info", "vmipaddress = #{vmipaddress}")
  log("info", "ipam_vmid = #{ipam_vmid} ipam_vmid.inspect = #{ipam_vmid.inspect} ipam_vmid.class = #{ipam_vmid.class}")

  # TODO check if it is really our name behind the registered IP
  # otherwise - try the whole thing again?
  # Retry if this failed
end

def register_ip_address()
  # This method registers the correct MAC address with the IP address

  # Lookup the record that has been created earlier? 
  # Or have it as a provisioning option?
  @hostfqdn = @prov.get_option(:vm_fqdn)

  ipam_vmid = @prov.get_option(:ipam_vmid)
  bam_delete(ipam_vmid)

  @vmmacaddress = @prov.vm.mac_addresses[0]

  log("info", "register_ip_address with values @hostfqdn = #{@hostfqdn}, ipam_vmid = #{ipam_vmid}, @vmmacaddress = #{@vmmacaddress}")
  bam_assign_ip4_address(@reservedip)
end

# Get provisioning object
@prov = $evm.root["miq_provision"]

@hostfqdn =""

vmsubnet, @dnsdomain = @prov.options[:vm_config_network].to_s.split
log("info", "vmsubnet => #{vmsubnet}, @dnsdomain => #{@dnsdomain}")

# Retrieve the configuration information for the network from Bluecat
@baseaddr, @cidrbits = vmsubnet.split(/\//)

# Login to IPAM already, and get required data for later requests,
# to reduce the time between name and IP reservation

bam_login

@ipam_configuration_id = bam_get_configuration_id()
@ipam_defaultview_id = bam_get_defaultview_id()

@reservedip = @prov.get_option(:vmipaddr)
if not @reservedip.nil?
  register_ip_address
  
  # Store the assigned IP address in a custom attribute of the freshly created virtual machine
  vm_name = @prov.get_option(:vm_target_name)
  vm = $evm.vmdb('vm').find_by_name(vm_name)
  log('info', "VM name = #{vm_name}, reservedip = #{@reservedip}, VM object = #{vm}")
  vm.custom_set('bluecat_ipaddress', @reservedip)
  
  # Call servers to deploy the changes
  @ipam_serverlist.split(",").each do |serverid|
    bam_deploy(serverid.to_s)
    sleep(@ipam_deploywait)
  end
else
  acquire_ip_address 
end

bam_logout

exit MIQ_OK
