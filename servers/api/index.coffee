nconf = require("nconf")
request = require("request")
mime = require("mime")
express = require("express")
url = require("url")
querystring = require("querystring")
_ = require("underscore")._
validator = require("json-schema")
mime = require("mime")

apiErrors = require("./errors")

module.exports = app = express.createServer()


genid = (len = 16, prefix = "", keyspace = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") ->
  prefix += keyspace.charAt(Math.floor(Math.random() * keyspace.length)) while len-- > 0
  prefix


mongoose = require("../../lib/stores/mongoose")

Session = mongoose.model("Session")
User = mongoose.model("User")
Plunk = mongoose.model("Plunk")

app.configure ->
  app.use require("./middleware/cors").middleware()
  app.use require("./middleware/json").middleware()
  app.use require("./middleware/session").middleware(sessions: mongoose.model("Session"))
    
  app.use app.router
  
  app.use (err, req, res, next) ->
    json = if err.toJSON? then err.toJSON() else
      message: err.message or "Unknown error"
      code: err.code or 500
    
    res.json(json, json.code)
    
    throw err
    
  app.set "jsonp callback", true

###
# RESTful sessions
###


createSession = (token, user, cb) ->
  session = new Session
    last_access: new Date
    keychain: {}
    
  session.user = user if user
  
  session.save (err) -> cb(err, session)

# Convenience endpoint to get the current session or create a new one
app.get "/session", (req, res, next) ->
  res.header "Cache-Control", "no-cache"
  
  if req.session then res.json(req.session)
  else createSession null, null, (err, session) ->
    if err then next(err)
    else res.json(session, 201)


app.post "/sessions", (req, res, next) ->
  createSession null, null, (err, session) ->
    if err then next(err)
    else res.json(session, 201)

app.get "/sessions/:id", (req, res, next) ->
  Session.findById(req.params.id).populate("user").run (err, session) ->
    if err then next(err)
    else unless session then next(new apiErrors.NotFound)
    else if Date.now() - session.last_access.valueOf() > nconf.get("session:max_age") then next(new apiErrors.NotFound)
    else
      unless session.user then res.json(session.toJSON())
      else User.findById session.user, (err, user) ->
        if err then next(err)
        else res.json(_.extend(session, user: user.toJSON()))



app.del "/sessions/:id/user", (req, res, next) ->
  Session.findById req.params.id, (err, session) ->
    if err then next(err)
    else unless session and session.user then next(new apiErrors.NotFound)
    else
      session.user = null
      
      session.save (err) ->
        if err then next(err)
        else res.json(session)

app.post "/sessions/:id/user", (req, res, next) ->
  Session.findById req.params.id, (err, session) ->
    if err then next(new apiErrors.NotFound)
    else
      unless token = req.param("token") then next(new apiErrors.MissingArgument("token"))
      else
        sessid = req.param("id")
        
        request.get "https://api.github.com/user?access_token=#{token}", (err, response, body) ->
          return next(new apiErrors.Error(err)) if err
          return next(new apiErrors.PermissionDenied) if response.status >= 400
      
          try
            body = JSON.parse(body)
          catch e
            return next(new apiErrors.ParseError)
          
          service_id = "github:#{body.id}"
          
          createUser = (cb) ->
            user_json =
              login: body.login
              gravatar_id: body.gravatar_id
              service_id: service_id
              
            User.create(user_json, cb)
          
          withUser = (err, user) ->
            if err then next(err)
            else
              session.user = user
              session.auth =
                service_name: "github"
                service_token: token
              session.save (err) ->
                if err then next(err)
                else res.json(_.extend(session.toJSON(), user: user.toJSON()), 201)
              
          User.findOne { service_id: service_id }, (err, user) ->
            unless err or not user then withUser(null, user)
            else createUser(withUser)




###
# Plunks
###

preparePlunk = (session, json) ->
  owner = false
  
  if session
    owner ||= !!(json.user and session.user and json.user.login is session.user.login)
    owner ||= !!(session.keychain and session.keychain.id(json.id)?.token is json.token)
  
  delete json.token unless owner
  
  json.files = do ->
    files = {}
    for file in json.files
      file.raw_url = "#{json.raw_url}#{file.filename}"
      files[file.filename] = file
    files
  
  json

preparePlunks = (session, plunks) -> _.map plunks, (plunk) -> preparePlunk(session, plunk.toJSON())


# List plunks
app.get "/plunks", (req, res, next) ->
  pp = Math.max(1, parseInt(req.param("pp", "12"), 10))
  start = Math.max(0, parseInt(req.param("p", "1"), 10) - 1) * pp
  end = start + pp
  
  Plunk.find({}).sort("updated_at", -1).limit(pp).skip(start).populate("user").run (err, plunks) ->
    if err then next(err)
    else res.json(preparePlunks(req.session, plunks))
  
# Create plunk
app.post "/plunks", (req, res, next) ->
  json = req.body
  schema = require("./schema/plunks/create")
  {valid, errors} = validator.validate(json, schema)
  
  # Despite its awesomeness, revalidator does not support disallow or additionalProperties; we need to check plunk.files size
  if json.files and _.isEmpty(json.files)
    valid = false
    errors.push
      attribute: "minProperties"
      property: "files"
      message: "A minimum of one file is required"
  
  unless valid then next(new apiErrors.ValidationError(errors))
  else
    
    json.user = req.user if req.user
    
    json.files = _.map json.files, (file, filename) ->
      filename: filename
      content: file.content
      mime: mime.lookup(filename, "text/plain")
    
    
    # TODO: This is inefficient as the number space fills up; consider: http://www.faqs.org/patents/app/20090063601
    # Keep generating new ids until not taken
    savePlunk = ->
      json._id = genid(6)
    
      Plunk.create json, (err, plunk) ->
        if err
          if err.code is 11000 then savePlunk()
          else next(err)
        else
          unless req.user
            req.session.keychain.push _id: plunk._id, token: plunk.token
            req.session.save()
          res.json(preparePlunk(req.session, plunk.toJSON()), 201)
          
    savePlunk()

# Read plunk
app.get "/plunks/:id", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").run (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else res.json(preparePlunk(req.session, plunk.toJSON()))

# Delete plunk
app.del "/plunks/:id", (req, res, next) ->
  Plunk.findById(req.params.id).populate("user").run (err, plunk) ->
    if err or not plunk then next(new apiErrors.NotFound)
    else unless preparePlunk(req.session, plunk.toJSON()).token then next(new apiErrors.NotFound)
    else plunk.remove ->
      res.send(204)

app.all "*", (req, res, next) ->
  next new apiErrors.NotFound