local responses = require "kong.tools.responses"
local crud = require "kong.api.crud_helpers"
local cjson = require "cjson"
local utils = require "kong.tools.utils"
local kstn_utils = require ("kong.plugins.keystone.utils")

ServiceAndEndpoint = {}

local available_service_types = {
    compute = true, ec2 = true, identity = true, image = true, network = true, volume = true
}

local available_interface_types = {
    public = true, internal = true, admin = true
}

function list_services(self, dao_factory)
    local resp = {
        links = {
            next = "null",
            previous = "null",
            self = self:build_url(self.req.parsed_url.path)
        },
        services = {}
    }

    local services = {}
    local err
    if self.params.type then
        services, err = dao_factory.service:find_all({type = self.params.type})
    else
        services, err = dao_factory.service:find_all()
    end

    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.services:find_all(...)"})
    end

    if not next(services) then
        return responses.send_HTTP_OK(resp)
    end

    for i = 1, #services do
        resp.services[i] = {}
        resp.services[i].description = services[i].description
        resp.services[i].id = services[i].id
        resp.services[i].links = {
                self = self:build_url(self.req.parsed_url.path)
        }
        resp.services[i].enabled = services[i].enabled
        resp.services[i].name = services[i].name
        resp.services[i].type = services[i].type
    end
    return responses.send_HTTP_OK(resp)
end

function create_service(self, dao_factory)
    local service = self.params.service
    if not service then
        return responses.send_HTTP_BAD_REQUEST("Service is nil, check self.params")
    end

    if not service.name then
        return responses.send_HTTP_BAD_REQUEST("Bad service name")
    end

    if not service.type or not available_service_types[service.type] then
        return responses.send_HTTP_BAD_REQUEST("Bad service type")
    end

    if not service.enabled then
        service.enabled = false
    end

    service.id = utils.uuid()

    local _, err = dao_factory.service:insert(service)
    if err then
        return responses.send_HTTP_CONFLICT(err)
    end

    service.links = {
                self = self:build_url(self.req.parsed_url.path)
            }
    return responses.send_HTTP_CREATED({service = service})
end

function get_service_info(self, dao_factory)
    local service_id = self.params.service_id
    if not service_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad service_id")
    end

    local service, err = dao_factory.service:find({id = service_id})
    if not service then
        return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
    end

    service.links = {
                self = self:build_url(self.req.parsed_url.path)
            }
    return responses.send_HTTP_OK({service = service})
end

function update_service(self, dao_factory)
    local service_id = self.params.service_id
    if not service_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad service_id")
    end

    local service, err = dao_factory.service:find({id = service_id})
    if not service then
        return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
    end

    if not self.params.service then
        return responses.send_HTTP_BAD_REQUEST("Error: self.params.service is nil")
    end

    if self.params.service.type then
        if not available_service_types[self.params.service.type] then
            return responses.send_HTTP_BAD_REQUEST("Bad service type")
        end
    end

    local updated_service, err = dao_factory.service:update(self.params.service, {id = service_id})
    if err then
        return responses.send_HTTP_CONFLICT(err)
    end

    updated_service.links = {
                self = self:build_url(self.req.parsed_url.path)
            }

    return responses.send_HTTP_OK({service = updated_service})
end

function delete_service(self, dao_factory)
    local service_id = self.params.service_id
    if not service_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad service_id")
    end

    local service, err = dao_factory.service:find({id = service_id})
    if not service then
        return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
    end

    local endpoints, err = dao_factory.endpoint:find_all({service_id = service_id})
    for i = 1, #endpoints do
        local _, err = dao_factory.endpoint:delete({id = endpoints[i].id})
        if err then
            return responses.send_HTTP_FORBIDDEN(err)
        end
    end

    local _, err = dao_factory.service:delete({id = service_id})
    return responses.send_HTTP_NO_CONTENT()
end

function list_endpoints(self, dao_factory)
    local resp = {
        links = {
            next = "null",
            previous = "null",
            self = self:build_url(self.req.parsed_url.path)
        },
        endpoints = {}
    }

    local args = {}
    if self.params.interface then
        if not available_interface_types[self.params.interface] then
            return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint interface")
        end
        args.interface = self.params.interface
    end

    if self.params.service_id then
        local service, err = dao_factory.service:find({id = self.params.service_id})
        if not service or err then
            return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
        end
        args.service_id = self.params.service_id
    end

    local endpoints = {}
    local err
    if next(args) then
        endpoints, err = dao_factory.endpoint:find_all(args)
    else
        endpoints, err = dao_factory.endpoint:find_all()
    end

    if err then
        return responses.send_HTTP_BAD_REQUEST({error = err, func = "dao_factory.endpoint:find_all(...)"})
    end

    if not next(endpoints) then
        return responses.send_HTTP_OK(resp)
    end

    for i = 1, #endpoints do
        resp.endpoints[i] = {}
        resp.endpoints[i].region_id = endpoints[i].region_id
        resp.endpoints[i].id = endpoints[i].id
        resp.endpoints[i].links = {
                self = self:build_url(self.req.parsed_url.path)
        }
        resp.endpoints[i].enabled = endpoints[i].enabled
        resp.endpoints[i].url = endpoints[i].url
        resp.endpoints[i].interface = endpoints[i].interface
        resp.endpoints[i].service_id = endpoints[i].service_id
    end
    return responses.send_HTTP_OK(resp)
end

function create_endpoint(self, dao_factory)
    local endpoint = self.params.endpoint
    if not endpoint then
        return responses.send_HTTP_BAD_REQUEST("endpoint is nil, check self.params")
    end

    if not endpoint.url then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint url")
    end

    if not endpoint.enabled then
        endpoint.enabled = true
    end

    if not endpoint.interface or not available_interface_types[endpoint.interface] then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint interface")
    end

    if not endpoint.service_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint service_id")
    end

    local service, err = dao_factory.service:find({id = endpoint.service_id})
    if not service or err then
        return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
    end

    if endpoint.region_id then
        local region, err = dao_factory.region:find({id = endpoint.region_id})
        if not region or err then
            return responses.send_HTTP_BAD_REQUEST("Error: no such region in the system")
        end
    end

    endpoint.id = utils.uuid()
    local _, err = dao_factory.endpoint:insert(endpoint)
    if err then
        return responses.send_HTTP_CONFLICT(err)
    end

    endpoint.links = {
                self = self:build_url(self.req.parsed_url.path)
    }

    return responses.send_HTTP_CREATED({endpoint = endpoint})
end

function get_endpoint_info(self, dao_factory)
    local endpoint_id = self.params.endpoint_id
    if not endpoint_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint_id")
    end

    local endpoint, err = dao_factory.endpoint:find({id = endpoint_id})
    if not endpoint then
        return responses.send_HTTP_BAD_REQUEST("Error: no such endpoint in the system")
    end

    endpoint.links = {
                self = self:build_url(self.req.parsed_url.path)
            }
    return responses.send_HTTP_OK({endpoint = endpoint})
end

function update_endpoint(self, dao_factory)
    local endpoint_id = self.params.endpoint_id
    if not endpoint_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint_id")
    end

    local endpoint, err = dao_factory.endpoint:find({id = endpoint_id})
    if not endpoint then
        return responses.send_HTTP_BAD_REQUEST("Error: no such endpoint in the system")
    end

    local new_endpoint = self.params.endpoint
    if not new_endpoint then
        return responses.send_HTTP_BAD_REQUEST("endpoint is nil, check self.params")
    end

    if new_endpoint.interface and not available_interface_types[new_endpoint.interface] then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint interface")
    end

    if new_endpoint.service_id then
       local service, err = dao_factory.service:find({id = new_endpoint.service_id})
        if not service or err then
            return responses.send_HTTP_BAD_REQUEST("Error: no such service in the system")
        end
    end

    if new_endpoint.region_id then
        local region, err = dao_factory.region:find({id = endpoint.region_id})
        if not region or err then
            return responses.send_HTTP_BAD_REQUEST("Error: no such region in the system")
        end
    end

    local updated_endpoint, err = dao_factory.endpoint:update(new_endpoint, {id = endpoint_id})

    if not updated_endpoint or err then
        return responses.send_HTTP_CONFLICT(err)
    end

    updated_endpoint.links = {
                self = self:build_url(self.req.parsed_url.path)
            }
    return responses.send_HTTP_OK({endpoint = updated_endpoint})
end

function delete_endpoint(self, dao_factory)
    local endpoint_id = self.params.endpoint_id
    if not endpoint_id then
        return responses.send_HTTP_BAD_REQUEST("Error: bad endpoint_id")
    end

    local endpoint, err = dao_factory.endpoint:find({id = endpoint_id})
    if not endpoint then
        return responses.send_HTTP_NOT_FOUND("Error: no such endpoint in the system")
    end

    local _, err = dao_factory.endpoint:delete({id = endpoint_id})
    if err then
        return responses.send_HTTP_FORBIDDEN(err)
    end

    return responses.send_HTTP_NO_CONTENT()
end

ServiceAndEndpoint.list_services = list_services
ServiceAndEndpoint.create_service = create_service
ServiceAndEndpoint.get_service_info = get_service_info
ServiceAndEndpoint.update_service = update_service
ServiceAndEndpoint.delete_service = delete_service

ServiceAndEndpoint.list_endpoints = list_endpoints
ServiceAndEndpoint.create_endpoint = create_endpoint
ServiceAndEndpoint.get_endpoint_info = get_endpoint_info
ServiceAndEndpoint.update_endpoint = update_endpoint
ServiceAndEndpoint.delete_endpoint = delete_endpoint

return {
    ["/v3/services"] = {
        GET = function(self, dao_factory)
            ServiceAndEndpoint.list_services(self, dao_factory)
        end,
        POST = function(self, dao_factory)
            ServiceAndEndpoint.create_service(self, dao_factory)
        end
    },
    ["/v3/services/:service_id"] = {
        GET = function(self, dao_factory)
            ServiceAndEndpoint.get_service_info(self, dao_factory)
        end,
        PATCH = function(self, dao_factory)
            ServiceAndEndpoint.update_service(self, dao_factory)
        end,
        DELETE = function(self, dao_factory)
            ServiceAndEndpoint.delete_service(self, dao_factory)
        end
    },
    ["/v3/endpoints"] = {
        GET = function(self, dao_factory)
            ServiceAndEndpoint.list_endpoints(self, dao_factory)
        end,
        POST = function(self, dao_factory)
            ServiceAndEndpoint.create_endpoint(self, dao_factory)
        end
    },
    ["/v3/endpoints/:endpoint_id"] = {
        GET = function(self, dao_factory)
            ServiceAndEndpoint.get_endpoint_info(self, dao_factory)
        end,
        PATCH = function(self, dao_factory)
            ServiceAndEndpoint.update_endpoint(self, dao_factory)
        end,
        DELETE = function(self, dao_factory)
            ServiceAndEndpoint.delete_endpoint(self, dao_factory)
        end
    }
}