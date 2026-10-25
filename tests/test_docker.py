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
if args == ['context', 'show']:
    print('test-context')
elif args[:2] == ['context', 'inspect']:
    print(json.dumps([{'Endpoints': {'docker': {'Host': data.get('host', 'unix:///test/docker.sock')}}}]))
elif args == ['info']:
    if data.get('denied') and not os.environ.get('FAKE_ROOT'):
        fail('permission denied')
elif args[:2] == ['ps', '-aq']:
    print('\n'.join(c['Id'] for c in data['containers']))
elif args[0] == 'inspect':
    found = [c for c in data['containers'] if c['Id'] in args[1:]]
    if len(found) != len(args[1:]):
        fail('container disappeared')
    print(json.dumps(found))
elif args[:2] == ['image', 'inspect']:
    image = data['images'].get(args[-1])
    if image is None:
        fail('image not found')
    print(json.dumps([{'Id': image, 'Os': 'linux', 'Architecture': 'amd64'}]))
elif args[0] == 'pull':
    ref = args[-1]
    if ref == data.get('pull_failure'):
        fail('registry unavailable', 42)
    data['images'][ref] = data['registry'].get(ref, data['images'].get(ref))
    if data.get('change_during_pull') == 'state':
        data['containers'][0]['State'] = {'Status': 'exited', 'Running': False}
    if data.get('change_during_pull') == 'config':
        next(iter(data['services'].values()))['hash'] = 'changed-after-confirmation'
    if data.get('change_during_pull') == 'replica' and len(data['containers']) == 1:
        replica = json.loads(json.dumps(data['containers'][0]))
        replica.update(Id='new-replica-id', Name='/new-replica')
        data['containers'].append(replica)
    save()
    print('Pulled ' + ref)
elif args[:2] == ['compose', 'version']:
    print('Docker Compose version test')
elif args[0] == 'compose':
    for option in ('--project-name', '--project-directory', '-f'):
        if option not in args:
            fail('missing Compose context: ' + option)
    project = args[args.index('--project-name') + 1]
    service = args[-1]
    spec = data['services'][project + '/' + service]
    if 'config' in args and '--hash' in args:
        print(service + ' ' + spec['hash'])
    elif 'config' in args and '--format' in args:
        print(json.dumps({'services': {service: spec['config']},
            'volumes': data.get('volumes', {}),
            'networks': data.get('networks', {'default': {'name': project + '_default', 'ipam': {}}})}))
    elif 'up' in args:
        if data.get('up_failure'):
            fail('health check failed', 43)
        for container in data['containers']:
            labels = container['Config']['Labels']
            if labels.get('com.docker.compose.project') == project and labels.get('com.docker.compose.service') == service:
                container['Image'] = data['images'][container['Config']['Image']]
                container['State']['Status'] = 'created' if '--no-start' in args else 'running'
                container['State']['Running'] = '--no-start' not in args
        save()
        print('Recreated ' + service)
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
        self.project = self.root / 'arbitrary project'
        self.project.mkdir(exist_ok=True)
        self.compose = self.project / 'compose.yaml'
        self.compose.write_text('services: {}\n')
        self.data = {'containers': [], 'images': {}, 'registry': {}, 'services': {}}

    def add_container(self, name='worker', service='api', project='sample', running=True,
                      image='example/app:latest', managed=True):
        labels = {}
        if managed:
            labels = {
                'com.docker.compose.project': project,
                'com.docker.compose.service': service,
                'com.docker.compose.project.config_files': str(self.compose),
                'com.docker.compose.project.working_dir': str(self.project),
                'com.docker.compose.config-hash': 'same-hash',
                'com.docker.compose.oneoff': 'False',
            }
            self.data['services'][project + '/' + service] = {
                'hash': 'same-hash', 'config': {'image': image, 'networks': {'default': None}}}
        container = {'Id': name + '-id', 'Name': '/' + name, 'Image': 'sha256:old',
            'Config': {'Image': image, 'Labels': labels},
            'State': {'Status': 'running' if running else 'exited', 'Running': running},
            'Mounts': [], 'HostConfig': {'Tmpfs': {}, 'RestartPolicy': {'Name': 'no'}},
            'NetworkSettings': {'Networks': {project + '_default': {}}},
            'ImageManifestDescriptor': {'platform': {'os': 'linux', 'architecture': 'amd64'}}}
        self.data['containers'].append(container)
        self.data['images'][image] = 'sha256:old'
        self.data['registry'][image] = 'sha256:new'
        return container

    def save(self):
        self.fixture.write_text(json.dumps(self.data))

    def calls(self):
        return [json.loads(line) for line in self.docker_trace.read_text().splitlines()]

    def operations(self, operation):
        return [call for call in self.calls() if operation in call]

    def update(self, selection='all', response='UPDATE'):
        self.save()
        return self.terminal_run(self.entry_point, 'docker', 'update', replies=(
            ('Select containers', selection + '\n'), ('Type UPDATE', response + '\n')))

    def test_module_registers_without_docker_access(self):
        result = self.maint('list')
        self.assertEqual(result.returncode, 0, result.stderr)
        for action in ('list', 'pull', 'update'):
            self.assertIn('docker\t' + action + '\tDocker\t', result.stdout)
        self.assertFalse(self.trace.exists())

    def test_list_discovers_and_sorts_running_stopped_and_unmanaged_containers(self):
        self.setup_docker()
        self.add_container('zeta', running=False)
        self.add_container('alpha', managed=False)
        self.save()
        result = self.maint('docker', 'list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index('alpha'), result.stdout.index('zeta'))
        self.assertIn('exited', result.stdout)
        self.assertIn('example/app:latest', result.stdout)
        self.assertFalse(self.operations('pull'))
        self.assertFalse(self.operations('up'))

    def test_empty_daemon_is_successful(self):
        self.setup_docker()
        self.save()
        for action in ('list', 'pull', 'update'):
            result = self.maint('docker', action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('No containers', result.stdout)

    def test_pull_deduplicates_images_and_never_restarts_containers(self):
        self.setup_docker()
        self.add_container('one')
        self.add_container('two', managed=False)
        self.save()
        result = self.maint('docker', 'pull')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.operations('pull')), 1)
        self.assertFalse(self.operations('up'))
        saved = json.loads(self.fixture.read_text())
        self.assertEqual(saved['images']['example/app:latest'], 'sha256:new')
        self.assertEqual(saved['containers'][0]['Image'], 'sha256:old')

    def test_noninteractive_update_does_not_mutate(self):
        self.setup_docker()
        self.add_container()
        self.save()
        result = self.maint('docker', 'update', input='UPDATE\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.operations('pull'))
        self.assertFalse(self.operations('up'))

    def test_update_uses_original_files_and_preserves_stopped_state(self):
        self.setup_docker()
        active = self.add_container('active', service='api')
        self.add_container('idle', service='jobs', running=False, image='example/jobs:alpine')
        override = self.project / 'extra settings.yaml'
        override.write_text('services: {}\n')
        env_file = self.project / 'settings.env'
        env_file.write_text('SECRET=test\n')
        active['Config']['Labels']['com.docker.compose.project.config_files'] += ',' + str(override)
        active['Config']['Labels']['com.docker.compose.project.environment_file'] = str(env_file)
        status, output = self.update()
        self.assertEqual(status, 0, output)
        updates = self.operations('up')
        self.assertEqual(len(updates), 2, output)
        api = next(call for call in updates if call[-1] == 'api')
        jobs = next(call for call in updates if call[-1] == 'jobs')
        self.assertIn(str(override), api)
        self.assertIn(str(env_file), api)
        self.assertIn('--no-deps', api)
        self.assertIn('--no-build', api)
        self.assertIn('--wait', api)
        self.assertIn('--no-start', jobs)
        self.assertNotIn('--wait', jobs)
        self.assertNotIn('SECRET=test', output)
        saved = json.loads(self.fixture.read_text())
        self.assertTrue(saved['containers'][0]['State']['Running'])
        self.assertFalse(saved['containers'][1]['State']['Running'])

    def test_update_skips_unchanged_images(self):
        self.setup_docker()
        self.add_container()
        self.data['registry']['example/app:latest'] = 'sha256:old'
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertFalse(self.operations('up'))
        self.assertIn('unchanged', output.lower())

    def test_missing_compose_files_or_changed_settings_are_not_applied(self):
        for mode in ('missing', 'drift', 'unmanaged'):
            with self.subTest(mode=mode):
                self.setup_docker()
                container = self.add_container(managed=mode != 'unmanaged')
                if mode == 'missing':
                    container['Config']['Labels']['com.docker.compose.project.config_files'] = '/missing/compose.yaml'
                if mode == 'drift':
                    self.data['services']['sample/api']['hash'] = 'different-hash'
                self.save()
                result = self.maint('docker', 'update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Skip', result.stdout)
                self.assertFalse(self.operations('pull'))
                self.assertFalse(self.operations('up'))

    def test_pull_failure_stops_before_any_recreation(self):
        self.setup_docker()
        self.add_container('a')
        self.add_container('b', service='other', image='example/other:latest')
        self.data['pull_failure'] = 'example/other:latest'
        status, output = self.update()
        self.assertNotEqual(status, 0, output)
        self.assertIn('registry unavailable', output)
        self.assertFalse(self.operations('up'))

    def test_replicas_are_updated_once_with_the_same_count(self):
        self.setup_docker()
        self.add_container('one')
        self.add_container('two')
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertEqual(len(self.operations('up')), 1)
        self.assertIn('api=2', self.operations('up')[0])

    def test_partial_replica_selection_is_not_expanded_silently(self):
        self.setup_docker()
        self.add_container('one')
        self.add_container('two')
        status, output = self.update(selection='1')
        self.assertEqual(status, 0, output)
        self.assertFalse(self.operations('up'))
        self.assertIn('replicas', output)

    def test_remote_context_is_not_replaced_by_local_sudo_docker(self):
        self.setup_docker()
        self.data['host'] = 'ssh://remote'
        self.save()
        result = self.maint('docker', 'list')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local', result.stdout.lower())
        self.assertFalse(self.operations('info'))

    def test_cancelled_update_has_no_mutations(self):
        self.setup_docker()
        self.add_container()
        status, output = self.update(response='update')
        self.assertEqual(status, 0, output)
        self.assertFalse(self.operations('pull'))
        self.assertFalse(self.operations('up'))

    def test_external_state_or_config_change_during_pull_is_not_overwritten(self):
        for change in ('state', 'config'):
            with self.subTest(change=change):
                self.setup_docker()
                self.add_container()
                self.data['change_during_pull'] = change
                status, output = self.update()
                self.assertEqual(status, 0, output)
                self.assertIn('Skipping', output)
                self.assertFalse(self.operations('up'))

    def test_selection_pulls_only_selected_image(self):
        self.setup_docker()
        self.add_container('alpha', image='example/alpha:latest')
        self.add_container('beta', image='example/beta:latest')
        self.save()
        status, output = self.terminal_run(self.entry_point, 'docker', 'pull',
            replies=(('Select containers', '2\n'),))
        self.assertEqual(status, 0, output)
        self.assertEqual([call[-1] for call in self.operations('pull')], ['example/beta:latest'])

    def test_health_failure_stops_remaining_services(self):
        self.setup_docker()
        self.add_container('one')
        self.add_container('two', service='worker', image='example/worker:latest')
        self.data['up_failure'] = True
        status, output = self.update()
        self.assertEqual(status, 43, output)
        self.assertIn('health check failed', output)
        self.assertEqual(len(self.operations('up')), 1)

    def test_mixed_replica_states_and_oneoff_containers_are_skipped(self):
        for mode in ('mixed', 'oneoff', 'swarm', 'paused', 'build'):
            with self.subTest(mode=mode):
                self.setup_docker()
                container = self.add_container('one')
                if mode == 'mixed':
                    self.add_container('two', running=False)
                if mode == 'oneoff':
                    container['Config']['Labels']['com.docker.compose.oneoff'] = 'True'
                if mode == 'swarm':
                    container['Config']['Labels']['com.docker.swarm.service.id'] = 'service-id'
                if mode == 'paused':
                    container['State']['Status'] = 'paused'
                if mode == 'build':
                    self.data['services']['sample/api']['config']['build'] = {'context': '.'}
                self.save()
                result = self.maint('docker', 'update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Skipping', result.stdout)
                self.assertFalse(self.operations('pull'))
                self.assertFalse(self.operations('up'))

    def test_numeric_and_digest_tags_are_not_rewritten(self):
        self.setup_docker()
        self.add_container('numeric', image='example/app:2.0')
        self.add_container('digest', service='other', image='example/app@sha256:' + 'a' * 64)
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertEqual({call[-1] for call in self.operations('pull')},
            {'example/app:2.0', 'example/app@sha256:' + 'a' * 64})
        self.assertEqual(self.compose.read_text(), 'services: {}\n')

    def test_permission_fallback_keeps_selected_socket(self):
        self.setup_docker()
        self.add_container()
        self.data['denied'] = True
        self.save()
        result = self.maint('docker', 'list')
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = [call for call in self.calls() if 'context' not in call]
        self.assertTrue(operations)
        self.assertTrue(all('unix:///test/docker.sock' in call for call in operations))

    def test_replica_added_during_pull_is_not_removed_by_stale_scale(self):
        self.setup_docker()
        self.add_container()
        self.data['change_during_pull'] = 'replica'
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertFalse(self.operations('up'))
        self.assertIn('replicas', output)

    def test_shared_image_is_pulled_and_compared_for_each_deployed_platform(self):
        self.setup_docker()
        self.add_container('native')
        foreign = self.add_container('foreign', service='foreign')
        foreign['ImageManifestDescriptor']['platform']['architecture'] = 'arm64'
        self.data['services']['sample/foreign']['config']['platform'] = 'linux/arm64'
        status, output = self.update()
        self.assertEqual(status, 0, output)
        pulls = self.operations('pull')
        self.assertEqual(len(pulls), 2, output)
        self.assertEqual({call[call.index('--platform') + 1] for call in pulls},
            {'linux/amd64', 'linux/arm64'})
        image_inspects = [call for call in self.calls() if 'image' in call and 'inspect' in call]
        self.assertTrue(all('--platform' in call for call in image_inspects))

    def test_classic_image_store_platform_is_resolved_from_installed_image(self):
        self.setup_docker()
        container = self.add_container()
        del container['ImageManifestDescriptor']
        self.data['images']['sha256:old'] = 'sha256:old'
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertEqual(len(self.operations('pull')), 1, output)
        self.assertIn('linux/amd64', self.operations('pull')[0])

    def test_top_level_resource_drift_is_rejected_even_with_matching_service_hash(self):
        for mode in ('volume', 'network', 'network-options', 'secrets', 'configs'):
            with self.subTest(mode=mode):
                self.setup_docker()
                container = self.add_container()
                spec = self.data['services']['sample/api']['config']
                if mode == 'volume':
                    spec['volumes'] = [{'type': 'volume', 'source': 'data', 'target': '/data'}]
                    self.data['volumes'] = {'data': {'name': 'different_data'}}
                    container['Mounts'] = [{'Type': 'volume', 'Name': 'original_data',
                        'Destination': '/data', 'RW': True}]
                if mode == 'network':
                    self.data['networks'] = {'default': {'name': 'other_network'}}
                if mode == 'network-options':
                    self.data['networks'] = {'default': {'name': 'sample_default', 'internal': True}}
                if mode in ('secrets', 'configs'):
                    spec[mode] = [{'source': 'credentials'}]
                self.save()
                result = self.maint('docker', 'update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Skipping', result.stdout)
                self.assertFalse(self.operations('pull'))
                self.assertFalse(self.operations('up'))

    def test_matching_persistent_mounts_and_external_network_are_supported(self):
        self.setup_docker()
        container = self.add_container()
        self.data['services']['sample/api']['config']['volumes'] = [
            {'type': 'volume', 'source': 'data', 'target': '/data'},
            {'type': 'bind', 'source': '/srv/config', 'target': '/config', 'read_only': True}]
        self.data['volumes'] = {'data': {'name': 'original_data'}}
        self.data['networks'] = {'default': {'name': 'sample_default', 'external': True}}
        container['Mounts'] = [
            {'Type': 'volume', 'Name': 'original_data', 'Destination': '/data', 'RW': True},
            {'Type': 'bind', 'Source': '/srv/config', 'Destination': '/config', 'RW': False}]
        status, output = self.update()
        self.assertEqual(status, 0, output)
        self.assertEqual(len(self.operations('up')), 1, output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
