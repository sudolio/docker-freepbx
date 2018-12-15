#!/usr/bin/php
<?php
/**
 * Module downloader for FreePBX.
 *
 * Usage: modown TYPE VERSION DESTINATION PACKAGES
 *
 *  TYPE - type of package, can be 'all' or 'sounds'
 *  VERSION - available major version, eg. 14.0
 *  DESTINATION - destination where should be content of package extracted
 *  PACKAGES - raw names of packages to download
 *
 * @link https://github.com/sudolio/freepbx
 * @author Martin Sudolsky <martin@sudolio.sk>
 * @copyright (c) 2018 Sudolio a.s.
 * @license MIT
 */


// @TODO: Add support for more mirrors.
define('MIRROR', 'mirror.freepbx.org');

if ($argc < 5)
{
	print("Invalid number of paremeters.\n");
	exit(1);
}

$type = $argv[1] == 'sounds' ? 'sounds' : 'all';
$version = $argv[2];
$dest_path = rtrim($argv[3], '/');

// create list of modules
$modules = [];
for ($i = 4; $i < $argc; $i++)
{
	$m = array_filter(array_map(function($v)
	{
		return trim($v);
	}, explode(' ', $argv[$i])));

	if (count($m) == 1)
	{
		$modules[] = $m[0];
	}
	else
	{
		$modules = array_merge($modules, $m);
	}
}


$xml_url = sprintf('http://%s/%s-%s.xml', MIRROR, $type, $version);

if (!$c = curl_init())
{
	print("Cannot init CURL handle.\n");
	exit(1);
}

curl_setopt_array($c, [
	CURLOPT_URL => $xml_url,
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_HEADER => false,
	CURLOPT_FORBID_REUSE => true
]);

if (!$r = curl_exec($c))
{
	printf("Cannot exec curl for '%s'.\n", $xml_url);
	exit(1);
}

curl_close($c);

// parse XML result
if (!$xml = simplexml_load_string($r))
{
	printf("Cannot parse result from '%s'.\n", $xml_url);
	exit(1);
}

$download_list = [];

if ($type == 'sounds')
{
	$sounds = $xml->children();

	foreach ($sounds->children() as $package)
	{
		if ($package->getName() != 'package')
		{
			continue;
		}

		$type = $module = $language = $format = $version = '';

		foreach ($package->children() as $node)
		{
			switch ($node->getName())
			{
				case 'type':
					$type = (string)$node;
					break;

				case 'module':
					$module = (string)$node;
					break;

				case 'language':
					$language = (string)$node;
					break;

				case 'format':
					$format = (string)$node;
					break;

				case 'version':
					$version = (string)$node;
					break;
			}
		}

		if (!in_array(sprintf('%s/%s/%s/%s', $type, $module, $language, $format), $modules))
		{
			continue;
		}

		$basename = sprintf('%s-%s-%s-%s-%s', $type, $module, $language, $format, $version);
		$filename = $basename . '.tar.gz';

		$download_list[] = [
			'name' => sprintf('%s %s %s', $module, $format, $version),
			'url' => sprintf('http://%s/sounds/%s', MIRROR, $filename),
			'filename' => preg_replace('/[^a-zA-Z0-9\-\._]/', '', preg_replace('/\.+/', '.', $filename)),
			'path' => $language,
			'touch' => '.' . $basename
		];
	}
}
else
{
	// modules in all
	foreach ($xml->children() as $module)
	{
		if ($module->getName() != 'module')
		{
			continue;
		}

		$rawname = $name = $location = $md5sum = $version = '';

		foreach ($module->children() as $node)
		{
			switch ($node->getName())
			{
				case 'repo':
					// skip commercial modules
					if ((string)$node == 'commercial')
					{
						continue 3;
					}
					break;

				case 'rawname':
					$rawname = (string)$node;

					if (!in_array($rawname, $modules))
					{
						continue 3;
					}

					// sanitize name
					$rawname = preg_replace('/[^a-zA-Z0-9\-]/', '', $rawname);
					break;

				case 'name':
					$name = (string)$node;
					break;

				case 'location':
					$location = (string)$node;
					break;

				case 'md5sum':
					$md5sum = (string)$node;
					break;

				case 'version':
					$version = (string)$node;

					// sanitize version
					$version = preg_replace('/[^a-zA-Z0-9_]/', '',
						preg_replace('/\./', '_', $version)
					);
					break;
			}
		}

		$download_list[] = [
			'name' => sprintf('%s %s', $rawname, $version),
			'url' => sprintf('http://%s/modules/%s', MIRROR, $location),
			'filename' => sprintf('%s.tgz', $rawname),
			'md5' => $md5sum
		];
	}
}

// download files
foreach ($download_list as $download)
{
	// download module
	if (!$c = curl_init())
	{
		print("Cannot init curl handle.\n");
		exit(1);
	}

	$filename = sprintf('%s/%s', $dest_path, $download['filename']);

	if (!$f = fopen($filename, 'w'))
	{
		printf("Cannot open filename '%s'.", $filename);
		exit(1);
	}

	curl_setopt_array($c, [
		CURLOPT_URL => $download['url'],
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_HEADER => false,
		CURLOPT_FORBID_REUSE => true,
		CURLOPT_FILE => $f
	]);

	printf("Downloading module '%s'...", $download['name']);

	if (!curl_exec($c))
	{
		printf("FAILED\n");
		@unlink($filename);
		exit(1);
	}

	$code = curl_getinfo($c, CURLINFO_HTTP_CODE);

	if ($code != 200)
	{
		print("FAILED\n");
		@unlink($filename);
		exit(1);
	}

	curl_close($c);
	fclose($f);

	// check MD5 sum with downloaded file if available
	if (!empty($download['md5']))
	{
		if (md5_file($filename) != $download['md5'])
		{
			printf("FAILED. MD5 does not match.\n");
			@unlink($filename);
			exit(1);
		}
	}

	$output = '';
	$ret = 0;
	$dst = sprintf('%s/%s', $dest_path, !empty($download['path']) ? rtrim($download['path'], '/') : '');

	if (!file_exists($dst))
	{
		mkdir($dst, 0777, true);
	}

	exec(sprintf('tar xfz %s -C %s', $filename, $dst), $output, $ret);

	if ($ret != 0)
	{
		print("FAILED. Cannot extract files from archive.\n");
		@unlink($filename);
		exit(1);
	}

	@unlink($filename);

	if (!empty($download['touch']))
	{
		touch($dest_path . '/' . $download['touch']);
	}

	print("OK\n");
}
