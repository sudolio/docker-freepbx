<?php
// @TODO: Add support for more mirrors.
define('MIRROR', 'mirror.freepbx.org');

if ($argc != 3)
{
	printf("Invalid number of paremeters.\n");
	exit;
}

$version = $argv[1];
$modules = array_filter(array_map(function($v)
{
	return trim($v);
}, explode(' ', $argv[2])));

$xml_url = sprintf('http://%s/all-%s.xml', MIRROR, $version);

if (!$c = curl_init())
{
	die("Cannot init CURL handle.\n");
}

curl_setopt_array($c, [
	CURLOPT_URL => $xml_url,
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_HEADER => false,
	CURLOPT_FORBID_REUSE => true
]);

if (!$r = curl_exec($c))
{
	die(
		sprintf("Cannot exec curl for '%s'.\n", $xml_url)
	);
}

curl_close($c);

// parse XML result
if (!$xml = simplexml_load_string($r))
{
	die(
		sprintf("Cannot parse result from '%s'.\n", $xml_url)
	);
}

foreach ($xml->children() as $module)
{
	if ($module->getName() != 'module')
	{
		continue;
	}

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

	// download module
	if (!$c = curl_init())
	{
		die("Cannot init curl handle.\n");
	}

	//$filename = sprintf('%s-%s.tgz', $rawname, $version);
	$filename = sprintf('%s.tgz', $rawname);

	if (!$f = fopen($filename, 'w'))
	{
		die(
			sprintf("Cannot open filename '%s'.", $filename)
		);
	}

	curl_setopt_array($c, [
		CURLOPT_URL => sprintf('http://%s/modules/%s', MIRROR, $location),
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_HEADER => false,
		CURLOPT_FORBID_REUSE => true,
		CURLOPT_FILE => $f
	]);

	printf("Downloading module '%s'...", $name);

	if (!curl_exec($c))
	{
		printf("FAILED\n");
		continue;
	}

	curl_close($c);
	fclose($f);

	if (md5_file($filename) != $md5sum)
	{
		printf("FAILED. MD5 does not match.\n");
		@unlink($filename);
		continue;
	}

	/*
	$output = '';
	$ret = 0;
	exec(sprintf('tar xfz %s', $filename), $output, $ret);

	if ($ret != 0)
	{
		printf("FAILED. Cannot extract files from archive.\n");
		@unlink($filename);
		continue;
	}

	@unlink($filename);
	*/

	printf("OK\n");
}
