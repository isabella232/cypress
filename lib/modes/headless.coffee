chalk      = require("chalk")
Promise    = require("bluebird")
inquirer   = require("inquirer")
user       = require("../user")
errors     = require("../errors")
Project    = require("../project")
project    = require("../electron/handlers/project")
Renderer   = require("../electron/handlers/renderer")

module.exports = {
  getId: ->
    ## return a random id
    Math.random()

  ensureAndOpenProjectByPath: (id, options) ->
    ## verify we have a project at this path
    ## and if not prompt the user to add this
    ## project. once added then open it.
    {projectPath} = options

    open = =>
      @openProject(id, options)

    Project.exists(projectPath).then (bool) =>
      ## if we have this project then lets
      ## immediately open it!
      return open() if bool

      ## else prompt to add the project
      ## and then open it!
      @promptAddProject(projectPath)
      .then(open)

  promptAddProject: (projectPath) ->
    console.log(
      chalk.yellow("We couldn't find a Cypress project at this path:"),
      chalk.blue(projectPath)
      "\n"
    )

    questions = [{
      name: "add"
      type: "list"
      message: "Would you like to add this project to Cypress?"
      choices: [{
        name: "Yes: add this project and run the tests."
        value: true
      },{
        name: "No:  don't add this project."
        value: false
      }]
    }]

    new Promise (resolve, reject) =>
      inquirer.prompt questions, (answers) =>
        if answers.add
          ## what happens if adding the project fails?
          ## TODO: handle this edge case since its communicating
          ## with our remote server. I think currently since this
          ## is a wrapped promise is that it will bubble all the way
          ## up and we will console.log the error and report it
          ## since it'll likely be NetworkError or something.
          ## But we should still gracefully handle this better
          ## and provide a custom error message.
          Project.add(projectPath).then ->
            console.log chalk.green("\nOk great, added the project.\n")
            resolve()
        else
          reject errors.get("PROJECT_DOES_NOT_EXIST")

  openProject: (id, options) ->
    ## now open the project to boot the server
    ## putting our web client app in headless mode
    ## - NO  display server logs (via morgan)
    ## - YES display reporter results (via mocha reporter)
    project.open(options.projectPath, {
      morgan:       false
      socketId:     id
      reporter:     true
      isHeadless:   true
      port:         options.port
      environmentVariables: options.environmentVariables
    })
    .catch {portInUse: true}, (err) ->
      errors.throw("PORT_IN_USE_LONG", err.port)

  createRenderer: (url) ->
    Renderer.create({
      url:    url
      width:  1280
      height: 720
      show:   false
      frame:  false
      type:   "PROJECT"
    })

  waitForRendererToConnect: (project, id) ->
    ## wait up to 10 seconds for the renderer
    ## to connect or die
    @waitForSocketConnection(project, id)
    .timeout(10000)
    .catch Promise.TimeoutError, (err) ->
      errors.throw("TESTS_DID_NOT_START")

  waitForSocketConnection: (project, id) ->
    new Promise (resolve, reject) ->
      fn = (socketId) ->
        if socketId is id
          ## remove the event listener if we've connected
          project.removeListener "socket:connected", fn

          ## resolve the promise
          resolve()

      ## when a socket connects verify this
      ## is the one that matches our id!
      project.on "socket:connected", fn

  waitForTestsToFinishRunning: (project) ->
    new Promise (resolve, reject) ->
      ## when our project fires its end event
      ## resolve the promise
      project.once "end", resolve

  runTests: (project, id) ->
    config = project.getConfig()

    ## we know we're done running headlessly
    ## when the renderer has connected and
    ## finishes running all of the tests.
    ## we're using an event emitter interface
    ## to gracefully handle this in promise land
    Promise.props({
      connection: @waitForRendererToConnect(project, id)
      stats:      @waitForTestsToFinishRunning(project)
      renderer:   @createRenderer(config.allTestsUrl)
    })

  ready: (options = {}) ->
    ## make sure we have a current session
    user.ensureSession()

    .then =>
      id = @getId()

      ## verify this is an added project
      ## and then open it, returning our
      ## project instance
      @ensureAndOpenProjectByPath(id, options)

      .then (project) =>
        console.log("\nTests should begin momentarily...\n")

        @runTests(project, id)
        .get("stats")
        .get("failures")

  run: (options) ->
    new Promise (resolve, reject) =>
      app = require("electron").app

      ## prevent chromium from throttling
      app.commandLine.appendSwitch("disable-renderer-backgrounding")

      app.on "ready", =>
        resolve @ready(options)
}
