#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes qw(time sleep);

# ============================================================
# Beállítás
# ============================================================

my $MAX_LINES_PER_SEC = 100;

# ============================================================
# Ellenőrzés
# ============================================================

if ($MAX_LINES_PER_SEC < 1)
{
	die "HIBA: A MAX_LINES_PER_SEC értéke legalább 1 legyen!\n";
}

# ============================================================
# STDIN / STDOUT beállítás
# ============================================================

binmode(STDIN);
binmode(STDOUT);

$| = 1;

# ============================================================
# Fő ciklus
# ============================================================

my $window_start = time();
my $line_count = 0;

while (my $line = <STDIN>)
{
	my $now = time();

	if (($now - $window_start) >= 1.0)
	{
		$window_start = $now;
		$line_count = 0;
	}

	if ($line_count >= $MAX_LINES_PER_SEC)
	{
		my $sleep_time = 1.0 - ($now - $window_start);

		if ($sleep_time > 0)
		{
			sleep($sleep_time);
		}

		$window_start = time();
		$line_count = 0;
	}

	print STDOUT $line;
	$line_count++;
}
