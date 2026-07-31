package RS41IPC;

use strict;
use warnings;
use utf8;

use Exporter qw(import);
use JSON::PP;
use Encode qw(encode_utf8 decode_utf8);
use IO::Handle;

our @EXPORT_OK = qw(
	json_codec
	configure_json_stdio
	send_json_message
	decode_json_line
	extract_json_messages
	make_frontend_event_request
	is_frontend_event_request
);

my $JSON = JSON::PP->new->canonical(1)->allow_nonref(1);

sub json_codec
{
	return $JSON;
}

sub configure_json_stdio
{
	binmode STDIN,  ':raw';
	binmode STDOUT, ':raw';
	binmode STDERR, ':encoding(UTF-8)';

	STDOUT->autoflush(1);

	return;
}

sub send_json_message
{
	my ($handle, $message) = @_;

	return 0 if !defined($handle);
	return 0 if ref($message) ne 'HASH';

	print {$handle} encode_utf8($JSON->encode($message) . "\n");

	return 1;
}

sub decode_json_line
{
	my ($line) = @_;

	return if !defined($line);

	my $decoded = decode_utf8($line, 1);
	$decoded =~ s/[\r\n]+\z//;

	my $message = eval
	{
		$JSON->decode($decoded);
	};

	return ref($message) eq 'HASH' ? $message : undef;
}

sub extract_json_messages
{
	my ($buffer_reference, $chunk) = @_;

	return () if ref($buffer_reference) ne 'SCALAR';

	$$buffer_reference .= $chunk // '';

	my @messages;

	while ($$buffer_reference =~ s/^(.*?\n)//s)
	{
		my $message = decode_json_line($1);
		push @messages, $message if ref($message) eq 'HASH';
	}

	return @messages;
}

sub make_frontend_event_request
{
	my ($event, %parameters) = @_;

	return if !defined($event) || $event eq '';

	return
	{
		type  => 'frontend_event_request',
		event => $event,
		%parameters
	};
}

sub is_frontend_event_request
{
	my ($message) = @_;

	return 0 if ref($message) ne 'HASH';
	return ($message->{type} // '') eq 'frontend_event_request' ? 1 : 0;
}

1;
