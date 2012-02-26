# Usage
<pre>
script/my_app deploy heroku [OPTIONS]

  # Create new app with randomly selected name and deploy
  script/my_app deploy heroku --create --api-key ...

  # Create new app with specified name and deploy
  script/my_app deploy heroku --create --name happy-cloud-1234

  # Deploy to existing app
  script/my_app deploy heroku --name happy-cloud-1234

These options are available:
  -n, --appname &lt;name&gt;      Specify app for deployment
  -a, --api-key &lt;api_key&gt;   Heroku API key (read from ~/.heroku/credentials by default).
  -c, --create              Create a new Heroku app
  -v, --verbose             Verbose output (heroku response, git output)
  -h, --help                This message
</pre>

# Example
<pre>
mojo generate app MyApp
cd my_app
script/my_app generate makefile
script/my_app generate heroku
script/my_app deploy heroku
</pre>
