"""Docker module integration tests; Docker and sudo are isolated command doubles."""

import json
import unittest

import test_maint


FAKE_DOCKER = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path

path = Path(os.environ['DOCKER_FIXTURE'])
data = json.loads(path.read_text())
args = sys.argv[1:]
with open(os.environ['DOCKER_TRACE'], 'a') as trace:
    trace.write(json.dumps(args) + '\n')
while args and args[0] in ('--host', '--config'):
    args = args[2:]
def save():
    path.write_text(json.dumps(data))
def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)
def owner(container):
    labels = container['Config']['Labels']
    return labels.get('com.docker.compose.project'), labels.get('com.docker.compose.service')
def tags(image_id):
    return sorted(ref for ref, tagged in data['images'].items() if tagged == image_id)
def in_use(image_id):
    return any(container['Image'] == image_id for container in data['containers'])
def oneoff(container):
    return container['Config']['Labels'].get('com.docker.compose.oneoff') == 'True'
def attached(network):
    return any(network in container['NetworkSettings']['Networks'] for container in data['containers'])
if args == ['context', 'show']:
    print('test-context')
elif args[:2] == ['context', 'inspect']:
    print(json.dumps([{'Endpoints': {'docker': {'Host': data.get('host', 'unix:///test/docker.sock')}}}]))
elif args == ['info']:
    if data.get('denied') and not os.environ.get('FAKE_ROOT'):
        fail('permission denied')
elif args[:3] == ['ps', '--all', '--quiet']:
    print('\n'.join(container['Id'] for container in data['containers']))
elif args[0] == 'inspect':
    found = [container for container in data['containers'] if container['Id'] in args[1:]]
    if len(found) != len(args[1:]):
        fail('container disappeared')
    print(json.dumps(found))
elif args[:2] == ['image', 'inspect']:
    if args[2] not in data['store']:
        fail('No such image')
    print(json.dumps([{'Id': args[2], 'RepoTags': tags(args[2])}]))
elif args[:2] == ['image', 'rm']:
    for target in args[2:]:
        image_id = data['images'].get(target, target)
        if in_use(image_id):
            fail('conflict: image is being used by a container')
        if target in data['images']:
            del data['images'][target]
        elif tags(image_id):
            fail('conflict: image is referenced in multiple repositories')
        if not tags(image_id):
            data['store'].remove(image_id)
    save()
    print('Deleted')
elif args[0] == 'rm':
    if any(c['Id'] in args[1:] and c['State']['Running'] for c in data['containers']):
        fail('cannot remove a running container')
    data['containers'] = [c for c in data['containers'] if c['Id'] not in args[1:]]
    save()
elif args[:2] == ['network', 'ls']:
    project = args[args.index('--filter') + 1].split('=')[-1]
    print('\n'.join(n['name'] for n in data['networks'] if n['project'] == project))
elif args[:2] == ['network', 'rm']:
    if any(attached(name) for name in args[2:]):
        fail('network has active endpoints')
    data['networks'] = [n for n in data['networks'] if n['name'] not in args[2:]]
    save()
elif args[:2] == ['compose', 'version']:
    print('Docker Compose version test')
elif args[0] == 'compose':
    args = args[1:]
    context = {}
    while args[0] in ('--project-name', '--project-directory', '--file', '--env-file'):
        context.setdefault(args[0], []).append(args[1])
        args = args[2:]
    if '--project-name' not in context or '--project-directory' not in context or '--file' not in context:
        fail('missing Compose context: ' + repr(context))
    project = context['--project-name'][0]
    services = data['projects'][project]
    command = args[0]
    members = [c for c in data['containers'] if owner(c)[0] == project and not oneoff(c)]
    if command == 'config' and '--hash' in args:
        for service in services:
            print(service, data['hashes'].get(project + '/' + service, 'same-hash'))
    elif command == 'config' and '--format' in args:
        print(json.dumps({'services': {service: {'image': ref} for service, ref in services.items()},
            'networks': {'default': {'name': project + '_default'}} |
                {n['name']: {'name': n['name']} for n in data['networks'] if n['project'] == project and n.get('defined')}}))
    elif command == 'config':
        if data.get('config_error') == project:
            fail('services.api.image: invalid reference')
    elif command == 'pull':
        for ref in sorted(set(services.values())):
            if ref == data.get('pull_failure'):
                fail('registry unavailable', 42)
            data['images'][ref] = data['registry'].get(ref, data['images'].get(ref))
            if data['images'][ref] not in data['store']:
                data['store'].append(data['images'][ref])
        if data.get('change_during_pull') == 'stop':
            for container in members:
                container['State'] = {'Status': 'exited', 'Running': False}
        save()
    elif command == 'up' and '--no-start' in args:
        if '--remove-orphans' in args:
            data['containers'] = [c for c in data['containers'] if c not in members or owner(c)[1] in services]
        for container in members:
            name, service = owner(container)
            if service in services:
                ref = services[service]
                if container['Image'] != data['images'][ref] or container['Config']['Image'] != ref:
                    container['Id'] += '-recreated'
                    container['Image'] = data['images'][ref]
                    container['Config']['Image'] = ref
                    container['State'] = {'Status': 'created', 'Running': False}
        save()
    elif command == 'up' and '--detach' in args and '--wait' in args:
        if data.get('up_failure'):
            fail('container is unhealthy', 43)
        for container in members:
            if owner(container)[1] in args:
                container['State'] = {'Status': 'running', 'Running': True}
        save()
    else:
        fail('unexpected Compose command: ' + repr(args))
else:
    fail('unexpected Docker command: ' + repr(args))
'''


class DockerTests(unittest.TestCase):
    setUp = test_maint.MaintTests.setUp
    command = test_maint.MaintTests.command
    run_script = test_maint.MaintTests.run_script
    maint = test_maint.MaintTests.maint
    terminal_run = test_maint.MaintTests.terminal_run

    def setup_docker(self):
        self.fixture = self.root / 'docker.json'
        self.docker_trace = self.root / 'docker-trace'
        self.docker_trace.unlink(missing_ok=True)
        self.env.update(DOCKER_FIXTURE=str(self.fixture), DOCKER_TRACE=str(self.docker_trace))
        for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'COMPOSE_FILE', 'COMPOSE_PROJECT_NAME'):
            self.env.pop(key, None)
        self.command('docker', FAKE_DOCKER)
        self.command('sudo', '#!/bin/bash\nif [[ "$1" == -v ]]; then exit 0; fi\nexport FAKE_ROOT=1\nexec "$@"\n')
        self.data = {'containers': [], 'images': {}, 'store': [], 'registry': {}, 'projects': {},
            'hashes': {}, 'networks': []}

    def compose_file(self, project):
        directory = self.root / 'projects with spaces' / project
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'compose.yaml'
        path.write_text('services: {}\n')
        return path

    def add_container(self, name, project='sample', service='api', running=True,
                      image='example/app:latest', managed=True):
        labels = {}
        if managed:
            compose = self.compose_file(project)
            labels = {
                'com.docker.compose.project': project,
                'com.docker.compose.service': service,
                'com.docker.compose.project.config_files': str(compose),
                'com.docker.compose.project.working_dir': str(compose.parent),
                'com.docker.compose.oneoff': 'False',
                'com.docker.compose.config-hash': 'same-hash',
            }
            self.data['projects'].setdefault(project, {})[service] = image
        old, new = 'sha256:old-' + image, 'sha256:new-' + image
        container = {'Id': name + '-id', 'Name': '/' + name, 'Image': old,
            'Config': {'Image': image, 'Labels': labels},
            'State': {'Status': 'running' if running else 'exited', 'Running': running},
            'NetworkSettings': {'Networks': {project + '_default' if managed else 'bridge': {}}}}
        self.data['containers'].append(container)
        self.data['images'][image] = old
        self.data['registry'][image] = new
        if old not in self.data['store']:
            self.data['store'].append(old)
        return container

    def save(self):
        self.fixture.write_text(json.dumps(self.data))

    def saved(self):
        return json.loads(self.fixture.read_text())

    def calls(self):
        if not self.docker_trace.exists():
            return []
        return [json.loads(line) for line in self.docker_trace.read_text().splitlines()]

    def operations(self, *words):
        return [call for call in self.calls() if all(word in call for word in words)]

    def mutations(self):
        return self.operations('pull') + self.operations('up') + self.operations('rm')

    def update(self, selection='all', answer='y'):
        self.save()
        return self.terminal_run(self.entry_point, 'docker', 'update', replies=(
            ('Select projects', selection + '\n'), ('Compose project(s)?', answer + '\n')))

    def test_module_registers_list_and_update_without_docker_access(self):
        result = self.maint('list')
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = [line.split('\t')[1] for line in result.stdout.splitlines() if line.startswith('docker\t')]
        self.assertEqual(actions, ['list', 'update'])
        self.assertFalse(self.trace.exists())

    def test_list_numbers_projects_in_name_order_and_changes_nothing(self):
        self.setup_docker()
        self.add_container('web', project='beta', running=False)
        self.add_container('loose', managed=False, image='example/loose:1')
        self.add_container('db', project='alpha', service='db', image='example/db:1')
        self.save()
        result = self.maint('docker', 'list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1\talpha\tdb\trunning\texample/db:1', result.stdout)
        self.assertIn('2\tbeta\tweb\texited\texample/app:latest', result.stdout)
        self.assertIn('-\t(none)\tloose\trunning\texample/loose:1', result.stdout)
        self.assertFalse(self.mutations())

    def test_empty_daemon_is_successful(self):
        self.setup_docker()
        self.save()
        for action in ('list', 'update'):
            result = self.maint('docker', action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('No containers', result.stdout)

    def test_update_applies_recorded_compose_context_and_keeps_stopped_services_stopped(self):
        self.setup_docker()
        api = self.add_container('api')
        self.add_container('jobs', service='jobs', running=False, image='example/jobs:1')
        self.add_container('idle', project='idle', running=False, image='example/idle:1')
        override = self.root / 'override settings.yaml'
        override.write_text('services: {}\n')
        env_file = self.root / 'settings.env'
        env_file.write_text('SECRET=test\n')
        for container in self.data['containers'][:2]:
            labels = container['Config']['Labels']
            labels['com.docker.compose.project.config_files'] += ',' + str(override)
            labels['com.docker.compose.project.environment_file'] = str(env_file)
        status, output = self.update()
        self.assertEqual(status, 0, output)
        converge = self.operations('up', '--no-start', 'sample')[0]
        files = [converge[i + 1] for i, word in enumerate(converge) if word == '--file']
        self.assertEqual(files, [api['Config']['Labels']['com.docker.compose.project.config_files'].split(',')[0],
            str(override)])
        self.assertIn(str(env_file), converge)
        started = self.operations('up', '--detach')
        self.assertEqual(len(started), 1, output)
        self.assertIn('api', started[0])
        self.assertNotIn('jobs', started[0])
        self.assertNotIn('SECRET=test', output)
        states = {c['Name']: (c['State']['Running'], c['Image']) for c in self.saved()['containers']}
        self.assertEqual(states, {'/api': (True, 'sha256:new-example/app:latest'),
            '/jobs': (False, 'sha256:new-example/jobs:1'), '/idle': (False, 'sha256:new-example/idle:1')})

    def test_every_project_is_pulled_before_any_project_changes(self):
        self.setup_docker()
        self.add_container('one', project='alpha')
        self.add_container('two', project='beta', image='example/other:1')
        status, output = self.update()
        self.assertEqual(status, 0, output)
        calls = self.calls()
        pulls = [i for i, call in enumerate(calls) if 'pull' in call]
        changes = [i for i, call in enumerate(calls) if 'up' in call or 'rm' in call]
        self.assertEqual(len(pulls), 2, output)
        self.assertLess(max(pulls), min(changes))

    def test_pull_failure_leaves_every_project_untouched(self):
        self.setup_docker()
        self.add_container('one', project='alpha')
        self.add_container('two', project='beta', image='example/other:1')
        self.data['pull_failure'] = 'example/other:1'
        status, output = self.update()
        self.assertEqual(status, 42, output)
        self.assertIn('registry unavailable', output)
        self.assertFalse(self.operations('up'))
        self.assertFalse(self.operations('rm'))

    def test_replaced_images_are_removed_only_when_unused_and_owned(self):
        old = 'sha256:old-example/app:latest'
        for mode in ('dangling', 'retagged', 'in-use', 'foreign-tag'):
            with self.subTest(mode=mode):
                self.setup_docker()
                self.add_container('api')
                if mode == 'retagged':
                    self.data['projects']['sample']['api'] = 'example/app:2'
                    self.data['registry']['example/app:2'] = 'sha256:app-2'
                if mode == 'in-use':
                    self.add_container('manual', managed=False)
                if mode == 'foreign-tag':
                    self.data['images']['backup/app:keep'] = old
                status, output = self.update()
                self.assertEqual(status, 0, output)
                saved = self.saved()
                self.assertEqual(old in saved['store'], mode in ('in-use', 'foreign-tag'), output)
                if mode == 'foreign-tag':
                    self.assertIn('backup/app:keep', output)
                    self.assertEqual(saved['images']['backup/app:keep'], old)

    def test_containers_of_services_removed_from_compose_are_deleted_within_the_project_only(self):
        self.setup_docker()
        self.add_container('api')
        self.add_container('retired', service='retired', image='example/retired:1')
        self.add_container('neighbor', project='neighbor', image='example/neighbor:1')
        self.add_container('manual', managed=False, image='example/manual:1')
        del self.data['projects']['sample']['retired']
        status, output = self.update(selection='2')
        self.assertEqual(status, 0, output)
        names = {c['Name'] for c in self.saved()['containers']}
        self.assertEqual(names, {'/api', '/neighbor', '/manual'})

    def test_settings_changes_and_removals_are_named_before_confirmation(self):
        self.setup_docker()
        self.add_container('api')
        self.add_container('worker', service='worker', image='example/worker:1')
        self.add_container('retired', service='retired', image='example/retired:1')
        del self.data['projects']['sample']['retired']
        self.data['hashes']['sample/api'] = 'port-changed'
        status, output = self.update(answer='n')
        self.assertEqual(status, 0, output)
        notes = output[:output.index('[y/N]')]
        self.assertIn('differ from the current containers for: api.', notes)
        self.assertIn('their containers will be removed: retired', notes)
        self.assertNotIn('worker', notes.split('[NOTE]', 1)[1])
        self.assertFalse(self.mutations())

    def test_cleanup_removes_unused_project_leftovers_and_keeps_what_is_in_use(self):
        self.setup_docker()
        self.add_container('api', running=False)
        for name, running in (('run-done', False), ('run-live', True)):
            container = self.add_container(name, running=running)
            container['Config']['Labels']['com.docker.compose.oneoff'] = 'True'
        self.data['containers'][-1]['NetworkSettings']['Networks']['sample_attached'] = {}
        self.data['networks'] = [{'name': name, 'project': project} for name, project in (
            ('sample_default', 'sample'), ('sample_legacy', 'sample'), ('sample_attached', 'sample'),
            ('neighbor_legacy', 'neighbor'))] + [{'name': 'sample_spare', 'project': 'sample', 'defined': True}]
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertIn('no warning conditions', output)
        saved = self.saved()
        self.assertEqual({c['Name']: c['State']['Running'] for c in saved['containers']},
            {'/api': False, '/run-live': True})
        self.assertEqual({n['name'] for n in saved['networks']},
            {'sample_default', 'sample_attached', 'sample_spare', 'neighbor_legacy'})
        self.assertIn('sha256:old-example/app:latest', saved['store'])
        removed = [call for call in self.operations('rm') if 'image' not in call and 'network' not in call]
        self.assertEqual(len(removed), 1)
        self.assertIn('--volumes', removed[0])

    def test_selection_limits_every_change_to_the_chosen_projects(self):
        self.setup_docker()
        self.add_container('one', project='alpha')
        self.add_container('two', project='beta', image='example/other:1')
        status, output = self.update(selection='2')
        self.assertEqual(status, 0, output)
        compose_calls = [call for call in self.calls() if 'compose' in call and 'version' not in call]
        self.assertTrue(compose_calls)
        self.assertTrue(all('beta' in call for call in compose_calls))
        self.assertEqual(self.saved()['containers'][0]['Image'], 'sha256:old-example/app:latest')

    def test_noninteractive_or_declined_update_changes_nothing(self):
        for mode in ('noninteractive', 'declined'):
            with self.subTest(mode=mode):
                self.setup_docker()
                self.add_container('api')
                self.save()
                if mode == 'noninteractive':
                    result = self.maint('docker', 'update', input='all\ny\n')
                    status, output = result.returncode, result.stdout
                else:
                    status, output = self.update(answer='n')
                self.assertEqual(status, 0, output)
                self.assertIn('nothing was changed', output)
                self.assertFalse(self.mutations())

    def test_projects_that_cannot_be_reproduced_are_skipped_without_changes(self):
        for mode in ('missing-file', 'missing-env', 'mixed-sources', 'unresolved'):
            with self.subTest(mode=mode):
                self.setup_docker()
                api = self.add_container('api')
                worker = self.add_container('worker', service='worker')
                labels = api['Config']['Labels']
                if mode == 'missing-file':
                    for container in (api, worker):
                        container['Config']['Labels']['com.docker.compose.project.config_files'] = '/missing/compose.yaml'
                if mode == 'missing-env':
                    for container in (api, worker):
                        container['Config']['Labels']['com.docker.compose.project.environment_file'] = 'absent.env'
                if mode == 'mixed-sources':
                    labels['com.docker.compose.project.config_files'] += ',' + labels['com.docker.compose.project.config_files']
                if mode == 'unresolved':
                    self.data['config_error'] = 'sample'
                self.save()
                result = self.maint('docker', 'update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Skipping sample', result.stdout)
                self.assertFalse(self.mutations())

    def test_containers_outside_compose_are_never_updated(self):
        self.setup_docker()
        self.add_container('manual', managed=False)
        self.save()
        result = self.maint('docker', 'update')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No Compose projects', result.stdout)
        self.assertFalse(self.mutations())

    def test_running_state_is_read_after_the_downloads(self):
        self.setup_docker()
        self.add_container('api')
        self.data['change_during_pull'] = 'stop'
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertFalse(self.operations('up', '--detach'))
        self.assertFalse(self.saved()['containers'][0]['State']['Running'])

    def test_health_failure_stops_remaining_projects_and_keeps_old_images(self):
        self.setup_docker()
        self.add_container('one', project='alpha')
        self.add_container('two', project='beta', image='example/other:1')
        self.data['up_failure'] = True
        status, output = self.update()
        self.assertEqual(status, 43, output)
        self.assertIn('container is unhealthy', output)
        self.assertEqual(len(self.operations('up', '--detach')), 1)
        self.assertFalse(self.operations('beta', 'up'))
        self.assertFalse(self.operations('rm'))

    def test_remote_context_is_not_replaced_by_local_sudo_docker(self):
        self.setup_docker()
        self.data['host'] = 'ssh://remote'
        self.save()
        result = self.maint('docker', 'list')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local', result.stdout.lower())
        self.assertFalse(self.operations('info'))

    def test_permission_fallback_keeps_selected_socket(self):
        self.setup_docker()
        self.add_container('api')
        self.data['denied'] = True
        self.save()
        result = self.maint('docker', 'list')
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = [call for call in self.calls() if 'context' not in call]
        self.assertTrue(operations)
        self.assertTrue(all('unix:///test/docker.sock' in call for call in operations))


if __name__ == '__main__':
    unittest.main(verbosity=2)
