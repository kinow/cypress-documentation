require("./environment")

## we are not requiring everything up front
## to optimize how quickly electron boots while
## in dev or linux production. the reasoning is
## that we likely may need to spawn a new child process
## and its a huge waste of time (about 1.5secs) of
## synchronous requires the first go around just to
## essentially do it all again when we boot the correct
## mode.

_         = require("lodash")
os        = require("os")
cp        = require("child_process")
path      = require("path")
Promise   = require("bluebird")
logger    = require("./logger")
errors    = require("./errors")
appData   = require("./util/app_data")
argsUtil  = require("./util/args")

exit = (code) ->
  process.exit(code)

exit0 = ->
  exit(0)

exitErr = (err) ->
  ## log errors to the console
  ## and potentially raygun
  ## and exit with 1
  errors.log(err)
  .then -> exit(1)

module.exports = {
  isCurrentlyRunningElectron: ->
    !!(process.versions and process.versions.electron)

  isLinuxAndHasNotDisabledGpu: (options) ->
    process.env["CYPRESS_ENV"] isnt "test" and os.platform() is "linux" and "--disable-gpu" not in process.argv

  runElectron: (mode, options) ->
    ## wrap all of this in a promise to force the
    ## promise interface - even if it doesn't matter
    ## in dev mode due to cp.spawn
    Promise.try =>
      ## if we have the electron property on versions
      ## that means we're already running in electron
      ## like in production and we shouldn't spawn a new
      ## process
      if @isCurrentlyRunningElectron()
        if @isLinuxAndHasNotDisabledGpu()
          return new Promise (resolve) ->
            args = ["."].concat(argsUtil.toArray(options))
            args.push("--disable-gpu")

            ## respawn the same process except with --disable-gpu
            electron = cp.spawn(process.execPath, args, {
              stdio: "inherit"
            })

            ## whenever our new child electron process
            ## closes then we pass this exit code on
            electron.on("close", resolve)

        else
          ## just run the gui code directly here
          ## and pass our options directly to main
          require("./electron")(mode, options);
      else
        ## sanity check to ensure we're running
        ## the local dev server. dont crash just
        ## log a warning
        require("./api").ping().catch (err) ->
          console.log(err.message)
          errors.warning("DEV_NO_SERVER")

        args = ["."].concat(argsUtil.toArray(options))

        new Promise (resolve) ->
          ## kick off the electron process and resolve the calling
          ## promise code when this new child process closes
          electron = cp.spawn("electron", args, { stdio: "inherit" })
          electron.on("close", resolve)

  openProject: (options) ->
    ## this code actually starts a project
    ## and is spawned from nodemon
    require("./project")(options.project).open()

  runServer: (options) ->
    args = {}

    _.defaults options, { autoOpen: true }

    if not options.project
      throw new Error("Missing path to project:\n\nPlease pass 'npm run server -- --project path/to/project'\n\n")

    if options.debug
      args.debug = "--debug"

    ## just spawn our own index.js file again
    ## but put ourselves in project mode so
    ## we actually boot a project!
    _.extend(args, {
      script:  "index.js"
      watch:  ["--watch", "lib"]
      ignore: ["--ignore", "lib/public"]
      verbose: "--verbose"
      exts:   ["-e", "coffee,js"]
      args:   ["--", "--mode", "openProject", "--project", options.project]
    })

    args = _.chain(args).values().flatten().value()

    cp.spawn("nodemon", args, {stdio: "inherit"})

    ## auto open in dev mode directly to our
    ## default cypress web app client
    if options.autoOpen
      _.delay ->
        require("./launcher").launch("http://localhost:2020/__")
      , 2000

    if options.debug
      cp.spawn("node-inspector", [], {stdio: "inherit"})

      require("opn")("http://127.0.0.1:8080/debug?ws=127.0.0.1:8080&port=5858")

  start: (argv = []) ->
    logger.info("starting desktop app", args: argv)

    ## make sure we have the appData folder
    appData.ensure()
    .then =>
      options = argsUtil.toObject(argv)

      ## else determine the mode by
      ## the passed in arguments / options
      ## and normalize this mode
      switch
        when options.removeIds
          options.mode = "removeIds"

        when options.version
          options.mode = "version"

        when options.smokeTest
          options.mode = "smokeTest"

        when options.returnPkg
          options.mode = "returnPkg"

        when options.logs
          options.mode = "logs"

        when options.clearLogs
          options.mode = "clearLogs"

        when options.getKey
          options.mode = "getKey"

        when options.generateKey
          options.mode = "generateKey"

        when options.exitWithCode?
          options.mode = "exitWithCode"

        when options.ci
          options.mode = "ci"

        when options.runProject
          ## go into headless mode
          ## when we have 'runProject'
          options.mode = "headless"

        else
          ## set the default mode as headed
          options.mode ?= "headed"

      ## remove mode from options
      mode    = options.mode
      options = _.omit(options, "mode")

      @startInMode(mode, options)

  startInMode: (mode, options) ->
    switch mode
      when "removeIds"
        require("./project").removeIds(options.projectPath)
        .then (stats = {}) ->
          console.log("Removed '#{stats.ids}' ids from '#{stats.files}' files.")
        .then(exit0)
        .catch(exitErr)

      when "version"
        require("./modes/pkg")(options)
        .get("version")
        .then (version) ->
          console.log(version)
        .then(exit0)
        .catch(exitErr)

      when "smokeTest"
        require("./modes/smoke_test")(options)
        .then (pong) ->
          console.log(pong)
        .then(exit0)
        .catch(exitErr)

      when "returnPkg"
        require("./modes/pkg")(options)
        .then (pkg) ->
          console.log(JSON.stringify(pkg))
        .then(exit0)
        .catch(exitErr)

      when "logs"
        ## print the logs + exit
        require("./electron/handlers/logs").print()
        .then(exit0)
        .catch(exitErr)

      when "clearLogs"
        ## clear the logs + exit
        require("./electron/handlers/logs").clear()
        .then(exit0)
        .catch(exitErr)

      when "getKey"
        ## print the key + exit
        require("./project").getSecretKeyByPath(options.projectPath)
        .then (key) ->
          console.log(key)
        .then(exit0)
        .catch(exitErr)

      when "generateKey"
        ## generate + print the key + exit
        require("./project").generateSecretKeyByPath(options.projectPath)
        .then (key) ->
          console.log(key)
        .then(exit0)
        .catch(exitErr)

      when "exitWithCode"
        require("./modes/exit")(options)
        .then(exit)
        .catch(exitErr)

      when "headless"
        ## run headlessly and exit
        @runElectron(mode, options)
        .then(exit0)
        .catch(exitErr)

      when "headed"
        @runElectron(mode, options)

      when "ci"
        ## run headlessly in ci mode and exit
        @runElectron(mode, options)
        .then(exit)
        .catch(exitErr)

      when "server"
        @runServer(options)

      when "openProject"
        ## open + start the project
        @openProject(options)

      else
        throw new Error("Cannot start. Invalid mode: '#{mode}'")
}
