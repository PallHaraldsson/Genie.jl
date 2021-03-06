module Router

using App
using HttpServer
using URIParser
using Genie
using AppServer
using URIParser
using Memoize
using Sessions

import HttpServer.mimetypes

export route, routes, params
export GET, POST, PUT, PATCH, DELETE

const GET     = "GET"
const POST    = "POST"
const PUT     = "PUT"
const PATCH   = "PATCH"
const DELETE  = "DELETE"

const routes = Array{Any,1}()
const params = Dict{Symbol,Any}()

function route_request(req::Request, res::Response, session::Session)
  empty!(params)

  if is_static_file(req.resource)
    Genie.config.server_handle_static_files && return serve_static_file(req.resource)
    return Response(404)
  end

  if isempty(routes)
    load_routes_from_file()
  elseif App.is_dev()
    empty!(routes)
    load_routes_from_file()
    Genie.load_models()
  end

  match_routes(req, res, session)
end

function route(params...; with::Dict{Symbol, Any} = Dict{Symbol, Any}())
  extra_params = Dict(:with => with)
  push!(routes, (params, extra_params))
end

function match_routes(req::Request, res::Response, session::Session)
  for r in routes
    route_def, extra_params = r
    protocol, route, to = route_def
    protocol != req.method && continue

    Genie.config.log_router && Genie.log("Router: Checking against " * route)

    parsed_route, param_names = parse_route(route)

    uri = URI(req.resource)
    regex_route = Regex("^" * parsed_route * "\$")

    (! ismatch(regex_route, uri.path)) && continue
    Genie.config.log_router && Genie.log("Router: Matched route " * uri.path)

    extract_uri_params(uri, regex_route, param_names)
    extract_extra_params(extra_params)

    return invoke_controller(to, req, res, params, session)
  end

  Genie.config.log_router && Genie.log("Router: No route matched - defaulting 404")
  Response( 404, Dict{AbstractString, AbstractString}(), "not found" )
end

function parse_route(route::AbstractString)
  parts = Array{AbstractString,1}()
  param_names = Array{AbstractString,1}()

  for rp in split(route, "/", keep = false)
    if startswith(rp, ":")
      param_name = rp[2:end]
      rp = """(?P<$param_name>\\w+)"""
      push!(param_names, param_name)
    end
    push!(parts, rp)
  end

  "/" * join(parts, "/"), param_names
end

function extract_uri_params(uri::URI, regex_route::Regex, param_names::Array{AbstractString,1})
  # in path params
  matches = match(regex_route, uri.path)
  for param_name in param_names
    params[Symbol(param_name)] = matches[param_name]
  end

  # GET params
  if ! isempty(uri.query)
    for query_part in split(uri.query, "&")
      qp = split(query_part, "=")
      (size(qp)[1] == 1) && (push!(qp, ""))
      params[Symbol(qp[1])] = qp[2]
    end
  end

  # POST params


  # JSON API pagination
  if ! haskey(params, Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)_number"))
    params[Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)_number")] = haskey(params, Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)[number]")) ? parse(Int, params[Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)[number]")]) : 1
  end
  if ! haskey(params, Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)_size"))
    params[Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)_size")] = haskey(params, Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)[size]")) ? parse(Int, params[Symbol("$(Genie.genie_app.config.pagination_jsonapi_page_param_name)[size]")]) : Genie.genie_app.config.pagination_jsonapi_default_items_per_page
  end
end

function extract_extra_params(extra_params::Dict{Symbol, Dict{Symbol, Any}})
  if ! isempty(extra_params[:with])
    for (k, v) in extra_params[:with]
      params[k] = v
    end
  end
end

const loaded_controllers = UInt64[]

function invoke_controller(to::AbstractString, req::Request, res::Response, params::Dict{Symbol, Any}, session::Session)
  to_parts = split(to, "#")

  controller_path = abspath(joinpath(Genie.APP_PATH, "app", "resources", to_parts[1]))
  controller_path_hash = hash(controller_path)
  if ! in(controller_path_hash, loaded_controllers) || Configuration.is_dev()
    Genie.load_controller(controller_path)
    Genie.export_controllers(to_parts[2])
    ! in(controller_path_hash, loaded_controllers) && push!(loaded_controllers, controller_path_hash)
  end

  controller = Genie.GenieController()
  action_name = string(current_module()) * "." * to_parts[2]

  params[:_req]       = req
  params[:_res]       = res
  params[:_session]   = session

  try
    response = invoke(eval(Genie, parse(string(current_module()) * "." * action_name)), (typeof(params),), params)
  catch ex
    Genie.log("$ex at $(@__FILE__), line $(@__LINE__)", :err)
    rethrow(ex) # do something better with the error
  end

  if ! isa(response, Response)
    if isa(response, Tuple)
      response = Response(response...)
    else
      response = Response(response)
    end
  end

  response
end

function load_routes_from_file()
  include(abspath("config/routes.jl"))
end

@memoize function is_static_file(resource::AbstractString)
  isfile(file_path(URI(resource).path))
end

function serve_static_file(resource::AbstractString)
  f = file_path(URI(resource).path)
  Response(200, file_headers(f), open(readbytes, f))
end

function file_path(resource::AbstractString)
  abspath(joinpath(Genie.config.server_document_root, resource[2:end]))
end
file_extension(f) = ormatch(match(r"(?<=\.)[^\.\\/]*$", f), "")
file_headers(f) = Dict{AbstractString, AbstractString}("Content-Type" => get(mimetypes, file_extension(f), "application/octet-stream"))

ormatch(r::RegexMatch, x) = r.match
ormatch(r::Void, x) = x

end