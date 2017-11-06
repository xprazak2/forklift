# Development Environments

This covers how to setup and configure a development environment using the Forklift tool suite.

 * [Development Environment Deployment](#development-environment-deployment)
 * [Use Koji Scratch Builds](#koji-scratch-builds)
 * [Test Puppet Module Pull Requests](#test-puppet-module-pull-requests)
 * [Jenkins Job Builder](#jenkins-job-builder-development)
 * [Redmine Development](#redmine-development)
 * [Hammer Development](#hammer-development)
 * [Capsule Development](#capsule-development)
 * [Client Development](#client-development)
 * [Webpack](#webpack)
 * [Dynflow](#dynflow-development)

## Development Environment Deployment

A Katello development environment can be deployed on CentOS 6 or 7. Ensure that you have followed the steps to [setup Vagrant and the libvirt plugin](vagrant.md). There are a variety of useful development environment options that should or can be set when creating a development box. These options are designed to configure your environment ready to use your own fork, and create pull requests. To create a development box:

  0. Ensure your workstation is configured to access your GitHub account.
  1. Copy `boxes.yaml.example` to `boxes.yaml`. If you already have a `boxes.yaml`, you can copy the entries in `boxes.yaml.example` to your `boxes.yaml`.
  2. Now, replace `<REPLACE ME>` with your github username.
  3. Fill in any ansible options, examples:
    * `foreman_devel_github_push_ssh`: Force git to push over SSH when HTTPS remote is configured
    * `ssh_forward_agent`: Forward local SSH keys to the box via ssh-agent
    * `katello_devel_github_username`: Your GitHub username to set up repository forks
    * `forwarded_port_host_ip`: control what IP port forwards bind to. '0.0.0.0' will bind to all. Defaults to '127.0.0.1'
  4. Fill in any foreman-installer options, examples:
    * `--katello-devel-use-ssh-fork`: will add your fork by SSH instead of HTTPS
    * `--katello-devel-fork-remote-name`: will change the naming convention for your fork's remote
    * `--katello-devel-upstream-remote-name`: will change the naming convention for the upstream (non-fork) repositories remote
    * `--katello-devel-extra-plugins`: specify other plugins to have setup and configured

For example, if I wanted my upstream remotes to be origin and to install the remote execution and discovery plugins:

```yaml
centos7-devel:
  box: centos7
  ansible:
    playbook: 'playbooks/devel.yml'
    group: 'devel'
    variables:
      katello_devel_github_username: <REPLACE ME>
      foreman_installer_options: "
        --katello-devel-upstream-remote-name origin
        --katello-devel-extra-plugins theforeman/foreman_remote_execution
        --katello-devel-extra-plugins theforeman/foreman_discovery
        "
```

Lastly, spin up the box:

```
vagrant up centos7-devel
```

If you get an error about the host CPU not providing the 'svm' feature but you most assuredly do have an Intel CPU and virtualization is most definitely turned on, add this to your Vagrantfile.

```
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |domain|
    domain.cpu_mode = "host-passthrough"
  end
end
```

Try to bring it up again with `vagrant up centos7-devel` after making that change.

If you get an error related to your user not having privileges to execute libvirt commands, create a polkit rule similar to the following:

```
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("wheel")) {
            return polkit.Result.YES;
    }
});
```

This rule will allow any user in the `wheel` group to perform libvirt commands. The file needs to reside in `/etc/polkit-1/rules.d`, named something like `49-org.libvirt.unix.manage.rules`. Now try to bring it up again with `vagrant up centos7-devel`.

You may experience some failures during the provisioning process. You may also find that rerunning `vagrant provision centos7-devel` will eventually result in a successful installation. If not, check error messages and logs for hints and/or seek help from the mailing list or IRC.

Once successfulling installed, access the box via ssh: `vagrant ssh centos7-devel`.

Before we can run the app, we need to install a couple things by hand to make webpack work.

Install `rh-nodejs8-npm` and `http-parser-devel`:

```
yum install rh-nodejs8-npm http-parser-devel
```

Enable the nodejs installation:

```
source /opt/rh/rh-nodejs8/enable
```

Execute `npm install`:

```
cd /home/vagrant/foreman
npm install
```

Set `:webpack_dev_server` to false in `~/foreman/config/settings.yaml` (until [#136](https://github.com/theforeman/puppet-katello_devel/pull/136)).
```yaml
:webpack_dev_server: false
```

If you are planning to make changes to the Webpack code, follow the [advanced webpack instructions](#webpack).

Now compile webpack:

```
bundle exec rake webpack:compile
```

And finally the Rails server can be started directly (this assumes you are connecting as the default `vagrant` user):

```
bin/rails s -b 0.0.0.0
```

The web application is forwarded to the host on port 3330 (HTTP) and 4430 (HTTPS).

## Koji Scratch Builds

Forklift supports using Koji scratch builds to make RPMs available for testing purposes. For example, if you want to test a change to nightly, with a scratch build of rubygem-katello. This is done by fetching the scratch builds, and deploying a local yum repo to the box you are deploying on. Multiple scratch builds are also supported for testing changes to multiple components at once (e.g. the installer and the rubygem), see examples below. Also, this option may be specified from within boxes.yaml via the `options:` option.


An Ansible role is provided that can setup and configure a Koji scratch build for testing. If you had an existing playbook such as:

```yaml
- hosts: server
  roles:
    - etc_hosts
    - foreman_repositories
    - katello_repositories
    - katello
```

The Koji role and task ID variable can be added to download and configure a repository with priority:

```yaml
- hosts: server
  vars:
    koji_task_id: 321231
  roles:
    - etc_hosts
    - koji
    - foreman_repositories
    - katello_repositories
    - katello
```

## Test Puppet Module Pull Requests

Testing installer puppet module pull requests is possible through an Ansible variable. Any number of modules and associated pull requests may be specified. For example, if a module under goes a refactoring, and you want to test that it continues to work with the installer. The pull requests are indicated by the github project, repository, and pull request number (eg. katello/qpid/23). Note that the name in this situation is the name as laid down in the module directory as opposed to the github repository name. In other words, use 'qpid' not 'puppet-qpid'. The pull requests are specified through the 'foreman_installer_module_prs' variable in the 'ansible' 'variables' section of your box definition. See examples below.

Single module PR in boxes.yaml:
```yaml
ansible:
  variables:
    foreman_installer_module_prs: "katello/katello_devel/97"
```

Multiple modules:
```yaml
ansible:
  variables:
    foreman_installer_module_prs: "katello/katello_devel/97,katello/qpid/34"
```

## Jenkins Job Builder Development

When modifying or creating new Jenkins jobs, it's helpful to generate the XML file to compare to the one Jenkins has. In order to do this, you need a properly configured Jenkins Job Builder environment. The dockerfile under docker/jjb can be used as a properly configured environment. To begin, copy `docker-compose.yml.example` to `docker-compose.yml`:

```
cd docker/jjb
cp docker-compose.yml.example docker-compose.yml
```

Now edit the docker-compose configuration file to point at your local copy of the `foreman-infra` repository so that it will mount and record changes locally when working within the container. Ensure that either your docker has permissions to the repository being mounted or that the appropriate Docker SELinux context is set: [Docker SELinux with Volumes](http://www.projectatomic.io/blog/2015/06/using-volumes-with-docker-can-cause-problems-with-selinux/). Now we are ready to do any Jenkins Job Builder work. For example, if you wanted to generate all the XML files for all jobs:

```
docker-compose run jjb bash
cd foreman-infra/puppet/modules/jenkins_job_builder/files/theforeman.org
jenkins-jobs -l debug test -r . -o /tmp/jobs
```

## Redmine Development

The Foreman project uses Redmine to handle issue management via forked instance of Redmine that runs on Openshift. Testing upgrades, making plugins or patches is sometimes desired to achieve functionality which we need. The dockerfile under docker/redmine can be used as a properly configured Redmine environment for development. To begin, copy `docker-compose.yml.example` to `docker-compose.yml`:

```
cd docker/redmine
cp docker-compose.yml.example docker-compose.yml
```

Assuming you have a clone of the Redmine repository somewhere locally, edit the `docker-compose.yml` configuration file to point at your local copy of the `redmine` repository so that it will mount and record changes locally when working within the container. Ensure that either your docker has permissions to the repository being mounted or that the appropriate Docker SELinux context is set: [Docker SELinux with Volumes](http://www.projectatomic.io/blog/2015/06/using-volumes-with-docker-can-cause-problems-with-selinux/). Now we are ready to start up Redmine and make changes:

```
docker-compose up redmine
```

## Hammer Development

Hammer is the command line interface (CLI) to Foreman and Katello. It supports plugins
such as [Foreman Tasks](https://github.com/theforeman/hammer-cli-foreman-tasks) and
importing/exporting data via [CSV](https://github.com/Katello/hammer-cli-csv).
The CLI can be configured to work with any version of Foreman. To facilitate
development in Hammer or any of its plugins, a lightweight vagrant box is
provided in the `boxes.yaml.example` file. To use this functionality, copy the
centos7-hammer-devel configuration from the example file into your `boxes.yaml`
file, changing options as necessary. Then run the following:

```sh
vagrant up centos7-hammer-devel
```

In the vagrant box, find the Hammer repositories at `/home/vagrant/` and the
configuration at `/home/vagrant/.hammer`.

## Capsule Development

To use this functionality, add the following configuration to your boxes.yaml,
changing the hostnames as needed

### To setup a smart proxy (capsule) and a new development environment

* setup boxes.yaml

```yaml
capsule-dev:
  box: centos7
  ansible:
    playbook: 'playbooks/foreman_proxy_content_dev.yml'
    group: 'foreman-proxy-content'
    server: 'foo'
```
* ```vagrant up foo```
* ssh into foo and ```rails s```
* ```vagrant up capsule-dev```


### To setup a capsule with an existing development environment

* Add the following to the existing Katello development server's configuration in boxes.yaml
```yaml
  ansible:
    group: 'server'
```
* Add a box for a capsule, using the katello server's name in the "server" field:

```yaml
capsule-dev:
  box: centos7
  ansible:
    playbook: 'playbooks/foreman_proxy_content_dev.yml'
    group: 'foreman-proxy-content'
    server: 'your-katello-server-name'
```
* ssh into existing development server and ```rails s```
* spin up new capsule ```vagrant up capsule-dev```

## Client Development

In boxes.yaml:

Add your client, replacing 'your-katello-server-name' with your main katello development server name

```yaml
awesome-client:
  box: centos7
  ansible:
    group: 'client'
    playbook: 'playbooks/katello_client.yml'
    variables:
      katello_client_server: 'your-katello-server-name'
      katello_client_organization: 'Default_Organization'
      katello_client_environment: 'Library'
      katello_client_username: 'admin'
      katello_client_password: 'changeme'

```
then add

```yaml
  ansible:
    group: 'server'
```

to the main katello server you want the client attached to

## Webpack

Forklift creates a reverse proxy between localhost:3000 (Rails development default server) and https://forkliftfqdn (e.g: https://centos7-devel.example.com). This will cause mixed-content errors if you try to enable the webpack server without any options, as it needs to use the right certificates for HTTPS and Foreman needs to allow it. Thus, to use the reverse proxy you need to follow these additional steps (while connected to the guest's shell):

Add/change the following variables in  `~/foreman/config/settings.yaml`:

```yaml
:webpack_dev_server: true
:webpack_dev_server_https: true
```

This will instruct Foreman to use Webpack from an https source.

Now recompile webpack:

```
bundle exec rake webpack:compile
```

Now we need to make sure Webpack is using the right certificates to serve the development content through HTTPS. We're going to save these configuration values on `~/foreman/.env`:

```
WEBPACK_OPTS='--https --key /etc/pki/katello/private/katello-default-ca.key --cert /etc/pki/katello/certs/katello-default-ca.crt --cacert /etc/pki/katello/certs/katello-default-ca.crt'
```

Remember to run `source ~/foreman/.env` before running your Webpack server, so that the right options to enable HTTPS are loaded.

Additionally, Foreman uses [secureheaders](https://github.com/twitter/secureheaders) to protect users from different attacks. secureheaders will block requests to the webpack development server, as it's not running in localhost:3000. To allow it, change the following lines in `~/foreman/config/initializers/secure_headers.rb`, substituting centos7-devel.example.com for your fqdn, you can get this value by running `hostname -f`.

```
    :style_src   => ["'unsafe-inline'", "'self'", 'centos7-devel.example.com:3808'],
    :script_src  => ["'unsafe-eval'", "'unsafe-inline'", "'self'", 'centos7-devel.example.com:3808'],
```

One last thing: Firefox will not like that webpack-dev-server is using a self-signed certificate. You should go to `https://centos7-devel.example.com:3008` (or your equivalent) and add an exception for this certificate. Chrome does not throw any warnings if you have accepted the same certificate already for `https://centos7-devel.example.com`.

After these changes, you should be able to run the webpack development server alongside with Foreman. Try it out by going to `~/foreman` and running `foreman start`. Happy hacking!

## Dynflow Development

DYNamic workFLOW orchestration engine http://dynflow.github.io

To use this box, copy the configuration from `boxes.yaml.example` to
`boxes.yaml`, changing options as necessary, then run the following:

```sh
vagrant up centos7-dynflow-devel
```

In the vagrant box, the dynflow repository is cloned to `/home/vagrant/dynflow`.
