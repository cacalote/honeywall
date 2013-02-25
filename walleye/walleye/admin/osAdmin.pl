#!/usr/bin/perl -w

# (C) 2005 The Honeynet Project.  All rights reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
#
#----- Authors: Scott Buchan <sbuchan@hush.com>

use strict;
use warnings;
use Template;

use CGI qw/:standard/;
use CGI::Carp 'fatalsToBrowser';
use File::stat;
use IO::Dir;

use Walleye::AdminUtils;

#  Validate login
my $session = validate_user();

my $role = $session->param("role");

if($role ne "admin") {
	error("You are not authorized to access this page.", "true");
}

 
my %hw_vars = hw_get_vars();

display_header_page($session);
display_page();
display_footer_page();

sub check_action {

	my $action = "";

	if(defined param("act")) {
		$action = param("act");
	}
	
	SWITCH: {
		if($action eq "cleanDir") { clean_dir(); last SWITCH;}
		if($action eq "configSSH") { config_ssh(); last SWITCH;}
		if($action eq "changeHostName") { change_host_name(); last SWITCH;}
		if($action eq "rebootHoneywall") { reboot_honeywall(); last SWITCH;}
		if($action eq "configKeyboard") { config_keyboard(); last SWITCH;}

	}

}

sub get_current_keyboard_settings {
	my $label;
	my $value;
        my $layout;
        my $keyboard_setting = "/etc/sysconfig/keyboard";
        open(FILE, "<$keyboard_setting" ) || error("Could not open $keyboard_setting $!");
        while (<FILE>)
        {
                if (/KEYTABLE/)
                {
                        my @values = split(/=/);
 			$value = $values[1];
                        $value =~ s/"//g;
			chomp($value);
                        close(FILE);
                        return $value;
                }
        }
        close(FILE);
}

sub config_keyboard {
	my $tmp_file = "/tmp/keyboard";
	my $keyboard_setting = "/etc/sysconfig/keyboard";
	my $setting = param("setting");
	my $cmd = "/bin/mv -f $tmp_file $keyboard_setting";
	my $loadkeys = "/bin/loadkeys $setting";
	my $status;
	my $title = "Configure Keyboard Layout";

	open(FILE, ">$tmp_file" ) || error("Could not open $tmp_file $!");

	print FILE "KEYBOARDTYPE=\"pc\"\n";
	print FILE "KEYTABLE=\"$setting\"\n";

	close(FILE);

	$status = system("sudo $cmd");
	error("Could not run command: $cmd $?") unless $status == 0;

	$status = system("sudo $loadkeys");
	error("Could not run command: $loadkeys $?") unless $status == 0;

	my $msg = "The keyboard layout has been configured.  ($setting) layout loaded.";
	display_admin_msg($title, $msg);
	
}

sub reboot_honeywall {
	my $status;
	my $cmd;
	
	$cmd = "/sbin/shutdown -r now";
	$status = system("sudo $cmd");
	error("Could not run $cmd $?") unless $status == 0;

}

sub change_host_name {

	my %input;
	my $status;
	my $proc;
	my $title = "Configure hostname of the system";
	my $tmp_file = "/tmp/tmp.hosts";
	my $file = "/etc/hosts";
	my $cmd = "mv -f $tmp_file $file";	
	my $host_extra = "/etc/hosts.extra";
	my $copy_extra = "/bin/cat $host_extra >> $tmp_file";
	my $domain = "";

	$input{"HwHOSTNAME"} = param("HwHOSTNAME");
	my $set_hostname = "/bin/hostname " . $input{"HwHOSTNAME"};

	$status = system("sudo $set_hostname");
	error("Could not run hostname $?") unless $status == 0;

	hw_set_vars(\%input);

	open(FILE,">$tmp_file") or error("Could not open file $tmp_file $!");

	print FILE "# /etc/hosts file for roo honeywall\n";
	print FILE "#\n";
	print FILE "# DO NOT EDIT THIS FILE to add hosts.  It is created by\n";
	print FILE "# the hw_sethostname function in /etc/rc.d/init.d/hwfuncs.sub.\n";
	print FILE "# Instead, put any extra host definitions in the file\n";
	print FILE "# /etc/hosts.extra and they will be included.\n";

	if(defined $hw_vars{"HwDOMAIN"}) {
		$domain = $hw_vars{"HwDOMAIN"};
	}

	if($hw_vars{"HwMANAGE_STARTUP"} eq "yes") {
		if($hw_vars{"HwMANAGE_IP"} ne "") {
			print FILE "127.0.0.1\t\t localhost localhost.localdomain\n";
			print FILE $hw_vars{"HwMANAGE_IP"} . "\t\t" . $input{"HwHOSTNAME"} . " " . $input{"HwHOSTNAME"} . "" . $domain . "\n";
		}
	} else {
		print FILE "127.0.0.1\t\t" . $input{"HwHOSTNAME"} . " localhost.localdomain localhost";
	}

	if (stat($host_extra)) {
		print FILE "\n";
		print FILE "# Reminder:  The following entries came from the file named\n";
		print FILE "# /etc/hosts.extra.  You should NOT EDIT this file if you\n";
		print FILE "# want to add new entries, rather put them in /etc/hosts.extra.\n";
		print FILE "# Don't say I didn't warn you! ;)\n";
		print FILE "#\n";
		print FILE "# P.S.  Any comments that come after this point DO NOT\n";
		print FILE "# change anything said above.  (That's because the user\n";
		print FILE "# who created /etc/hosts.extra put them there, not me!)\n";
		print FILE "\n";
    }

	close(FILE);

	if (stat($host_extra)) {
		# Copy contents of host.extra to hosts file
        $status = system("sudo $copy_extra");
        error("Could not run $copy_extra $?") unless $status == 0;
	}

	$status = system("sudo $cmd");
	error("Could not run $cmd $?") unless $status == 0;

	my $msg = "The hostname of the system has been changed to " . $input{"HwHOSTNAME"};
	display_admin_msg($title, $msg);


}

sub config_ssh {

	my %input;
	my $conf_dir = get_conf_dir();
	my $status;
	my $key;
	my $file;
	my @process;
	my $proc;
	my $title = "SSH Administration";
	my $msg = "SSHD has been restarted";
	
	$input{"HwSSHD_PORT"} = param("HwSSHD_PORT");
	$input{"HwSSHD_REMOTE_ROOT_LOGIN"} = param("HwSSHD_REMOTE_ROOT_LOGIN");
	$input{"HwSSHD_STARTUP"} = param("HwSSHD_STARTUP");
	
	if ($input{"HwSSHD_REMOTE_ROOT_LOGIN"} ne "yes") {
		$input{"HwSSHD_REMOTE_ROOT_LOGIN"} = "no";
	}

	if ($input{"HwSSHD_STARTUP"} ne "yes") {
		$input{"HwSSHD_STARTUP"} = "no";
	}

	$process[0] = "/dlg/config/hw_build_ssh_config.sh > /dev/null";
	$process[1] = "/etc/rc.d/init.d/sshd stop > /dev/null";
	$process[2] = "/etc/rc.d/init.d/sshd start > /dev/null";
	$process[3] = "/etc/rc.d/init.d/rc.firewall restart > /dev/null";


	hw_set_vars(\%input);
	
	# loop through process array here
	foreach $proc (@process) {
		$status = system("sudo $proc");
		error("Could not run $proc $?") unless $status == 0;
	}

	display_admin_msg($title, $msg);


}

sub clean_dir {

	my $status;
	my $dir;
	my $file;
	my $logdir = get_log_dir();
	my $title = "Clean out Honeywall directories";
	my $msg = "Honeywall directory cleanup successful.";
	my @directories = ("pcap", "snort", "snort_inline");
	my @files = ("iptables");
   
        my $cmd = "/etc/init.d/hwdaemons log_cleanout_stop > /dev/null"; 
        $status = system("sudo $cmd");
        error("Could not run $cmd $?") unless $status == 0;    

	foreach $dir (@directories) {
		my $cmd = "sudo rm -rf $logdir/$dir/*";
		$status = system("$cmd");
		error("Could not run process: $cmd $?") unless $status == 0;
	}

	foreach $file (@files) {
		my $path = "$logdir/$file";
		my $cmd = "sudo rm -f $path";
		$status = system("$cmd");
		error("Could not run process: $cmd $?") unless $status == 0;

		my $cmd2 = "sudo /bin/touch $path";
		$status = system("$cmd2");
		error("Could not run command: $cmd2 $?") unless $status == 0;
	}

    	#Here to give daemons enough time to clean up before they are started again
	sleep 3;

        $cmd = "/etc/init.d/hwdaemons log_cleanout_start > /dev/null"; 
        $status = system("sudo $cmd");
        error("Could not run $cmd $?") unless $status == 0;    

	display_admin_msg($title, $msg);

}

sub display_page {

	my $input;
	my %keyboard_settings;
	my $cur_keyboard_layout;

	# Refresh honeywall variables
	my %hw_vars = hw_get_vars();
	my $log_dir = get_log_dir();

	 my $disp = "";

        if(defined param("disp")) {
                $disp = param("disp");
        }

	check_action();
	
	SWITCH: {
		if($disp eq "cleanDir") { $input = "templates/osCleanDir.htm"; last SWITCH;}
		if($disp eq "configSSH") { $input = "templates/osConfigSSH.htm"; last SWITCH;}
		if($disp eq "changeHostName") { $input = "templates/osChangeHostName.htm"; last SWITCH;}
		if($disp eq "rebootHoneywall") { $input = "templates/osRebootHoneywall.htm"; last SWITCH;}
		if($disp eq "configKeyboard") { $input = "templates/osConfigKeyboard.htm"; 
										%keyboard_settings = get_keyboard_settings();
$cur_keyboard_layout = get_current_keyboard_settings();
										last SWITCH;}

		$input = "templates/admin.htm";

	}

	my $tt = Template->new( );
	
	my $vars  = {
		vars => \%hw_vars,
		keyboardSettings => \%keyboard_settings,
		logDir => $log_dir,
		curKeyboardLayout => $cur_keyboard_layout,
	};
	
	$tt->process($input, $vars)
	    || die $tt->error( );


}

sub get_keyboard_settings {

	my $kb_dir = "/lib/kbd/keymaps/i386";
	my $start_name;
	my $start_map;
	my $language;
	my @tmp;
	my $keyboard  = new IO::Dir("$kb_dir");
	my %settings;

	while(defined($start_name = $keyboard->read)){
    	if (defined($start_map = new IO::Dir("$kb_dir/$start_name"))){
        	while (defined($language = $start_map->read)){
            	#if file is a .map.gz
                if ($language =~ /.map.gz$/){
                	#We need the name without extension
                    $language =~ s/.map.gz$//;
					if ($language =~ /^be/){$settings{"be"} = "Belgium";next;}
					if ($language =~ /^bg/){$settings{"bg"} = "Bulgaria";next;}
                    if ($language =~ /^br/){$settings{"br"} = "Brazil";next;}
                    if ($language =~ /^by/){$settings{"by"} = "Bielorussia";next;}
                    if ($language =~ /^cf/){$settings{"cf"} = "Canada French";next;}
                    if ($language =~ /^cz/){$settings{"cz"} = "Czech Republic";next;}
                    if ($language =~ /^dk/){$settings{"dk"} = "Denmark";next;}
                    if ($language =~ /^es/){$settings{"es"} = "Spain";next;}
                    if ($language =~ /^fi/){$settings{"fi"} = "Finland";next;}
                    if ($language =~ /^fr/){$settings{"fr"} = "France";next;}
                    if ($language =~ /^gr/){$settings{"gr"} = "Greece";next;}
                    if ($language =~ /^hu/){$settings{"hu"} = "Hungary";next;}
                    if ($language =~ /^il/){$settings{"il"} = "Israel";next;}
                    if ($language =~ /^is/){$settings{"is"} = "Iceland";next;}
                    if ($language =~ /^it/){$settings{"it"} = "Italy";next;}
                    if ($language =~ /^jp/){$settings{"jp"} = "Japan";next;}
                    if ($language =~ /^la/){$settings{"la"} = "Latin America";next;}
                    if ($language =~ /^lt/){$settings{"lt"} = "Lithuania";next;}
                    if ($language =~ /^mk/){$settings{"mk"} = "Macedonia";next;}
                    if ($language =~ /^nl/){$settings{"nl"} = "The Netherlands";next;}
                    if ($language =~ /^no/){$settings{"no"} = "Norway";next;}
                    if ($language =~ /^pl/){$settings{"pl"} = "Poland";next;}
                    if ($language =~ /^pt/){$settings{"pt"} = "Portugal";next;}
                    if ($language =~ /^ro/){$settings{"ro"} = "Romania";next;}
                    if ($language =~ /^ru/){$settings{"ru"} = "Russia";next;}
                    if ($language =~ /^se/){$settings{"se"} = "Sweden";next;}
                    if ($language =~ /^sk/){$settings{"sk"} = "Slovakia";next;}
                    if ($language =~ /^sr/){$settings{"sr"} = "Serbia";next;}
                    if ($language =~ /^tr/){$settings{"tr"} = "Turkey";next;}
                    if ($language =~ /^ua/){$settings{"ua"} = "Ukraine";next;}
                    if ($language =~ /^uk/){$settings{"uk"} = "United Kingdom";next;}
                    if ($language =~ /^us/){$settings{"us"} = "United States";next;}
                    if ($language =~ /^cr/){$settings{"cr"} = "Croatia";next;}
                    if ($language =~ /^de/){$settings{"de"} = "Germany";next;}
                    if ($language =~ /^sg/){$settings{"sg"} = "Swiss German";next;}
                    if ($language =~ /^sl/){$settings{"sl"} = "Slovenia";}
				}
			}
		}
	}
	return %settings;
}	