
#!/exlibris/aleph/a23_1/product/bin/perl
#Script for updating saltuation for Aleph (used in letters) according to configured academic degrees. 
#Description and more: https://github.com/osulib/ALEPH-Academic-Salutations-
#
#RC1 - a. in some cases, order or perl hash can be changed. To preserve the oreder use perl Tie::StoredOrderHash
#             Instalation of cpan module for Aleph Perl distribution (as Aleph user):	> /exlibris/product/bin/perl -MCPAN -eshell
#      b. running the script can be easily switched to debug mode by configuring the carable $debug_mode to true value (1)       										install Tie::StoredOrderHash
#RC2 - set feminine on 'ova'. If gender is missing in patron data, can be set to "F" if name (surname) ends "ová" (common Czech feminine surname endning)
#	new parameter in config file setFeminineOnOva (if true as in Perl, do this)
#ENH1 - set of first names can be added in json format: name_gender.json  If parameter name_gender_derive is true, this json is loaded and i patron has no gender, the data is used to add the gender. 20250912

use strict;
use warnings;
use utf8;
use List::Util 'first';  
binmode(STDOUT, ":utf8");
binmode(STDIN, ":utf8");
use URI::Escape;
use POSIX qw/strftime/;
use Data::Dumper;
use DBI;
use LWP;
use XML::Simple;
use locale;
use Env;
use FindBin '$Bin';
#20201120 - nastaveno nove encoding dle skutecbeho stavu databaze, asi od ver23
#$ENV{NLS_LANG} = 'AMERICAN_AMERICA.AL32UTF8';
use Tie::StoredOrderHash; #RC1
$ENV{NLS_LANG} = 'American_America.UTF8';


my $logfile='academic_salutations.log';
open ( LOGFILE, ">>$logfile" );
binmode(LOGFILE, ":utf8");
my $tajmstemp = strftime "%Y%m%d-%H:%M:%S", localtime;
print LOGFILE "START $tajmstemp\n\n";
my $report_header="ACADEMIC SALUTATIONS REPORT ($tajmstemp)\n\n";
my $report_subject="Academic Salutations Report";
our $report_updated='';
my $report_unmatched='';
our $mail_error='';
our $debug_mode=1; #RC1
our $name_gender_derive=1; #ENH1

our $from_email='aleph@somemachine.com';
if ( $ENV{'HOST'} ) { $from_email='aleph@'.$ENV{'HOST'}; }
our $report_email='';

sub run_exemption {
   my $error_message=$_[0];
   my $die=''; if ( $_[1]) {$die=$_[1];}
   print "$error_message\n";
   print LOGFILE "ERROR - $error_message\n";
   $mail_error .=  "ERROR - $error_message\n\n";
   if ( $die eq 'die' ) { 
      open(MAIL, "|/usr/sbin/sendmail -t") or print LOGFILE "ERROR while sending mail. Mail script '/usr/sbin/sendmail' cannot be opened"; 
      binmode(MAIL, ":utf8");
      print MAIL "To: $report_email\n";
      print MAIL "From: $from_email\n";
      print MAIL "Subject: ALEPH Academic Salutations FATAL ERROR\n\n";
      print MAIL $mail_error;
      close(MAIL);
      die 'R.I.P.';}
   };

sub trim($) { my $string = shift; $string =~ s/^\s+//; $string =~ s/\s+$//; return $string; }
sub rtrim($) { my $string = shift; $string =~ s/\s+$//; return $string; }
sub rpad { my($str, $len, $chr) = @_; $chr = " " unless (defined($chr)); return substr($str . ($chr x $len), 0, $len); }



#0.1. read config file
my $config_file="$Bin/academic_salutations.conf";
my %settings=();
#our %salutations=();
tie our %salutations, 'Tie::StoredOrderHash'; #RC1
open(CONFFILE, "<:encoding(utf-8)", $config_file) or run_exemption ("Configuration file $config_file nout found (could nor be read). Exiting.",'die');
my $conf_gender='';
while ( my $line = <CONFFILE>) {
   ##chomp;
   if ( $line =~ m/^[;!\#]/ || $line =~ m/^\s*$/ ) { next; } #pass comments and empty lines
   if ( $line =~ m/^\s*([a-z][a-z0-9_]*)\s*=\s*(.*?)\s*$/i) { #config part 1
      $settings{lc($1)} = $2; }
   elsif ( $line =~ /^\s*[0-9]+/) {  #config part 2
      $line=rpad($line,122);
      $conf_gender=substr($line,14,1);
      if ( ! ( $conf_gender eq 'M' || $conf_gender eq 'F' || $conf_gender eq 'B' || $conf_gender eq ' ' ) ) {
         run_exemption("ALERT! Configuration file $config_file: A gender (column 3) has unacceptable value: $conf_gender in line:\n$line\n"); }
      elsif ( $conf_gender eq 'B' ) {
	 $salutations{ trim(substr($line,0,2)) }{ trim(substr($line,3,11)) }{ 'M' }{ substr($line,16,3) } = rtrim(substr($line,20,100)); 
	 $salutations{ trim(substr($line,0,2)) }{ trim(substr($line,3,11)) }{ 'F' }{ substr($line,16,3) } = rtrim(substr($line,20,100)); }
      else {
	 $salutations{ trim(substr($line,0,2)) }{ trim(substr($line,3,11)) }{ substr($line,14,1) }{ substr($line,16,3) } = rtrim(substr($line,20,100)); }
      }
   else {run_exemption("ALERT! Configuration file $config_file mischmatch, line:\n$line has not been recognized"); next; }
   }
close (CONFFILE);

if ( $settings{'report_email'} ) { $report_email=$settings{'report_email'}; }
else { run_exemption("ALERT! REPORT_EMAIL is missing in config file. The result will not be send to a mail!!");}
unless ( $settings{'adm_base'} ) { run_exemption("Conf. setting ADM_BASE not found. Possible mistake in $config_file config file",'die'); }
my $admBase=$settings{'adm_base'};
unless ( $settings{'adm_base_password'} ) { run_exemption("Conf. setting ADM_BASE_PASSWORD  not found. Possible mistake in $config_file config file",'die'); }
my $admBasePass=$settings{'adm_base'};
unless ( $settings{'xserver_url'} ) { run_exemption("Conf. setting XSERVER_URL not found. Possible mistake in $config_file config file",'die'); }
our $xserver_url=$settings{'xserver_url'};
our $update_bor_user='';
if ( $settings{'update_bor_user'} ) { $update_bor_user=$settings{'update_bor_user'}; }
our $update_bor_user_pas=''; 
if ( $settings{'update_bor_user_password'} ) { $update_bor_user_pas=$settings{'update_bor_user_password'}; }
unless ( $settings{'ora_sid'} ) { run_exemption("Conf. setting ORA_SID not found. Possible mistake in $config_file config file",'die'); }
unless ( $settings{'ora_host'} ) { run_exemption("Conf. setting ORA_HOST not found. Possible mistake in $config_file config file",'die'); }
my $sid = 'dbi:Oracle:host='.$settings{'ora_host'}.';sid='.$settings{'ora_sid'};
my $surname_method=' '; 
if ( $settings{'surname_get_method'} ) { $surname_method=$settings{'surname_get_method'}; }
my $default_bor_lang='XXX'; 
if ( $settings{'default_bor_lang'} ) { $default_bor_lang=$settings{'default_bor_lang'}; }
my $report_no_updates='N';
if ( $settings{'report_no_updates'} ) { $report_no_updates=$settings{'report_no_updates'}; }
our @excl_salut;
if ( $settings{'excluded_salutations'} ) { @excl_salut = split /\s*\|\s*/, $settings{'excluded_salutations'}; }
my @excl_ids;
if ( $settings{'excluded_ids'} ) { 
   $settings{'excluded_ids'} =~ s/^\s*//; $settings{'excluded_ids'} =~ s/\s*$//;
   @excl_ids = split /\s+/, $settings{'excluded_ids'}; }

sub update_bor {
   my ( $level, $borid, $name, $surname, $title, $gender, $lang, $old_salutation, $new_salutation) = @_;
#   if ( length($new_salutation)==0 ) { return 0;} #do not modify salutation, if config file has an empty string
   for my $exclude_it ( @excl_salut ) {
      if ( $exclude_it eq $old_salutation ) { return 0;} #patron has salution that should be excluded from updates
      }
   if ( @excl_ids ) {
      if ( first { /^$borid$/ } @excl_ids ) { print $borid; } #patrin id is wxcluded by configfile - excluded IDS
      }
   #check if patron does not hava a higher level salutation already
   my $higher_salutation='';
   for ( my $higher_level=$level-1; $higher_level>0; $higher_level-- ) {
      for $higher_salutation ( values %{$salutations{$higher_level}} ) {
         if ( $higher_salutation->{$gender}->{$lang} ) {
            my $check_salutation = $higher_salutation->{$gender}->{$lang};
            print "level $level higher_level $higher_level check_salutation $check_salutation old_salutation $old_salutation\n" if ($debug_mode);
            print LOGFILE "level $level higher_level $higher_level check_salutation $check_salutation old_salutation $old_salutation\n"  if ($debug_mode);
            if ( index($check_salutation,'{surname}')!= -1  ) {
               $check_salutation =~ s/\{surname\}/$surname/;  }
            if ( $check_salutation eq $old_salutation ) { 
               print "surname $surname has higher level\n"  if ($debug_mode);
               print LOGFILE "surname $surname has higher level\n" if ($debug_mode);
               return 0;} # patron has a higher level salutation already
            }
         }
      }
   #create plif xml for update-bor
   print "$borid $name, ".trim($title)." ($gender,$lang) - changing '$old_salutation' to '$new_salutation'\n";
   print LOGFILE "$borid $name, ".trim($title)." ($gender,$lang) - changing '$old_salutation' to '$new_salutation'\n";
   $report_updated .= "$borid $name, ".trim($title)." ($gender,$lang) - changing '$old_salutation' to '$new_salutation'\n";
   my $upd_bor={};
   ##$upd_bor->{'patron-record'}->{'z303'} = $xbor->{'z303'}; from Aleph ver. 19up it's not needed to include all elements, just those that should be updated, 
                                                              #Leaving out the elements will keep the current values of the fields.
   $upd_bor->{'patron-record'}->{'z303'}->{'match-id-type'} = '00';
   $upd_bor->{'patron-record'}->{'z303'}->{'match-id'} = $borid;
   $upd_bor->{'patron-record'}->{'z303'}->{'record-action'} = 'U';
   $upd_bor->{'patron-record'}->{'z303'}->{'z303-salutation'} = $new_salutation;
   print "upd_bor is ".Dumper($upd_bor)  if ($debug_mode);
   my $xupd_bor = XMLout($upd_bor, XMLDecl => 1, RootName => 'p-file-20', NoAttr => 1, KeyAttr => [  ], NoIndent => 1);
   #update-bor
   my $update_request = LWP::UserAgent->new;
   my $post_update = $update_request->post( $xserver_url,
       [ 'op' => 'update-bor',
         'library' => $admBase,
         'user_name' => $update_bor_user,
         'user_password' => $update_bor_user_pas,
         'update_flag' => 'Y', #change this to 'N' for testing (DB will not be updated)
         'xml_full_req' => $xupd_bor ]
       );
   unless ( $post_update->is_success ) { run_exemption("Patron ID $borid ERROR - no response from x-server update-bor: ".$post_update->status_line); return 0;}
#check response update bor
   my $xresponse_upd = XMLin( $post_update->content, ForceArray=>1 );
   if ( $xresponse_upd->{error} ) {
      my $ier=0;
      while ( $xresponse_upd->{error}[$ier] ) {
         unless ( index ($xresponse_upd->{error}[$ier], "Succeeded" )>-1 ) {
            run_exemption("Error in bor-update x-service, whan handling patron $borid : ".$xresponse_upd->{error}[$ier]);}
         $ier++;
         }
      }
   }


#ENH1 - load names and their genders
our $name_gender;
if ( $name_gender_derive ) {
   my $name_gender_text = '';
   open(my $json_fh, "<:encoding(UTF-8)", "$Bin/name_gender.json") or  run_exemption ('ERROR - name_gender_derive is in use, but data json file name_gender.json cannot be loaded','die');
   foreach (<$json_fh>) {
      $name_gender_text .= $_;
      };
   my $json = JSON->new;
   $name_gender = $json->decode($name_gender_text);
   }
#ENH1 end

#0.2. backup
print "z303 table backup (p_file_03)\n";
system ( 'csh -f '.$ENV{'aleph_proc'}.'/p_file_03 '.uc($admBase).',z303 >/dev/null' );
if ( $?!=0 ) {run_exemption("Backup p_file_03 z303 have not finished properly (error $?). \nCHECK IT!!!",'die');}


#1. get patron id, title and salotiaon from db to hash
my $dbh = DBI->connect($sid, $admBase,$admBasePass) or run_exemption ("ERROR couldn't connect to database as user ".$admBase."\n".$DBI::errstr);

my $surname_sql='\' \'';
if ( $surname_method eq 'F') {
   $surname_sql='nvl( regexp_replace( regexp_substr(z303_name,\'^[^,]+,\'), \',$\', \'\'), \'\')'; }
elsif ( $surname_method eq 'L' ) {
   $surname_sql='nvl( regexp_substr(z303_name,\'[^ ]+$\'), \'\')'; }
elsif ( $surname_method eq 'S' ) {  #check db table structure first
   my $sth_check = $dbh->prepare('select 1 from user_tab_columns where table_name=\'Z303\' and COLUMN_NAME=\'Z303_LAST_NAME\'');   
   $sth_check->execute or run_exemption ("ERROR in sql check if Z303_LAST_NAME column exist (user_tab_columns table): ".$DBI::errstr);
   if ( ! $sth_check->fetch() ) { 
      run_exemption ("WARNING: Table z303 does not contain column Z303_LAST_NAME (implemented in Aleph ver. 22 up).\nNo Surnames will be included"); }
   else { $surname_sql='Z303_LAST_NAME surname'; }
   }

print "Retrieving z303 global patron infos from DB, user/base $admBase ...\n";
my $sth = $dbh->prepare("select trim(z303_rec_key) borid, trim(z303_name) name, $surname_sql surname, Z303_TITLE title, Z303_GENDER gender, Z303_CON_LNG lang, nvl(z303_salutation,'') salutation from z303 where z303_rec_key!='87274'");
$sth->execute or run_exemption ("ERROR in sql select ... from z303 ...: ".$DBI::errstr,'die');


#2. parse data from database, compare to config settings and update using xserver, if necessary
print "Parsing the retrieved patrons one by one:\n"  ;
my $salut_match=0; my $salut_text='';
while ( my $patron=$sth->fetchrow_hashref() ) {
   $salut_match=0;
   if(utf8::is_utf8($patron->{SALUTATION})) { utf8::decode($patron->{SALUTATION}); }
   if(utf8::is_utf8($patron->{SURNAME})) { utf8::decode($patron->{SURNAME}); }
   if(utf8::is_utf8($patron->{TITLE})) { utf8::decode($patron->{TITLE}); }
   unless ( $patron->{LANG} ) { $patron->{LANG}=$default_bor_lang; }
   unless ( $patron->{GENDER} ) { $patron->{GENDER}=' '; }
   unless ( $patron->{SALUTATION} ) { $patron->{SALUTATION}=''; }
   unless ( $patron->{SURNAME} ) { $patron->{SURNAME}=''; }
   unless ( $patron->{TITLE} ) { $patron->{TITLE}=''; }
   #RC2
   if ( $setFeminineOnOva ) { unless ( $patron->{GENDER} ) {
      if ( $patron->{SURNAME} =~ m/ová$/ ) { $patron->{GENDER} = 'F'; }
           } }
   #RC2 end

      #ENH1
   if ( $name_gender_derive and $patron->{GENDER} eq ' ') {
           print LOGFILE $patron->{NAME} . " has no gender ... trying to derive it.\n";
           my $first_name = ''; $first_name=$patron->{NAME};
           $first_name =~ s/^[^,]+, //;
           unless ( $first_name ) { print LOGFILE "     Warning - no first name derived from the name ".$patron->{NAME}."\n"; }
           else {
              foreach my $gender_line ( @{ $name_gender->{'lines'} } ) {
                      #print Dumper($gender_line);
                      if ( $gender_line->{name} eq $first_name ){
                              print LOGFILE "      name ".$gender_line->{name}.' should have gender '.$gender_line->{gender}."\n";
                              $patron->{GENDER} = $gender_line->{gender};
                              last;
                      }

           }
           }


   }
   #ENH1 end


   print "DEBUG patron ".$patron->{SURNAME}."has now title". $patron->{TITLE}."\n" if ($debug_mode);
   if ( $patron->{TITLE} ) {  #check if db patron has title (is not null) etc. 
      print "DEBUG has title ".$patron->{TITLE}."\n" if ($debug_mode);
      for my $level ( keys %salutations ) { #go through level 1,2,3....
         for my $title ( keys %{ $salutations{$level} } ) { #go throught salutations in each level
            if ( index( uc($patron->{TITLE}), uc($title) ) > -1  ) { #title from db matches with salutation
               print "DEBUG title from db matches with salutation\n" if ($debug_mode);
	       for my $gender ( keys %{ $salutations{$level}{$title} } ) { #go throught genders
                  if ( $gender eq $patron->{GENDER} ) {
                     print "DEBUG pat has matchig gender ".$patron->{GENDER}."\n" if ($debug_mode);
                     for my $lang ( keys %{ $salutations{$level}{$title}{$gender} } ) { #go through languages
                        if ( $lang eq $patron->{LANG} ) {  
                           $salut_match=1;
                           #add surname
                           $salut_text=$salutations{$level}{$title}{$gender}{$lang};
			   $salut_text =~ s/^\s+|\s+$//g;
                           print "DEBUG salutation should be $salut_text\n" if ($debug_mode);
			   if ( index($salut_text,'{surname}')!= -1  ) {
			      $salut_text =~ s/\{surname\}/$patron->{SURNAME}/;  }
                           if ( ($patron->{SALUTATION} ne $salut_text) ) { # salutation in db does not match config settings (with surname if used)
                              print "DEBUG update salutation\n" if ($debug_mode);
                              update_bor( $level, $patron->{BORID}, $patron->{NAME}, $patron->{SURNAME}, 
					  $patron->{TITLE}, $patron->{GENDER}, $patron->{LANG}, 
					  $patron->{SALUTATION}, $salut_text);
                              }
                           }
                        }
                     }
                  }
               }
            }
         }
      if ( $salut_match==0 ) { $report_unmatched.= $patron->{BORID}." ".$patron->{NAME}.", ".trim($patron->{TITLE})." (".$patron->{GENDER}.",".$patron->{LANG}.")\n";  }
      }
   }

#mail report
if ($report_email ne '') {
   if ( $report_no_updates eq 'Y' || ( $report_no_updates ne 'Y' && $report_updated ne '' ) ) {
      print "Sending mail to $report_email\n";
      open(MAIL, "|/usr/sbin/sendmail -t") or run_exemption("ERROR while sending mail. Mail script '/usr/sbin/sendmail' cannot be opened");
      binmode(MAIL, ":utf8");
      print MAIL "To: $report_email\n";
      print MAIL "From: $from_email\n";
      if ( $mail_error ne '' ) { $report_subject .= ' - ERROR !'; }
      print MAIL "Subject: $report_subject\n\n";
      print MAIL $report_header;
      if ( $mail_error ne '' ) { print MAIL "$mail_error\n\n"; }
      if ( $report_updated ne '' ) { print MAIL "PATRONS' SALUTATIONS THAT HAVE BEEN UPDATED:\n\n$report_updated\n"; }
         else { print MAIL "No salutations have been updated\n\n"; }
      if ( $report_unmatched ne '' ) { print MAIL "\n\nPATRONS' TITLES THAT DOES NOT MATCH THE CONFIGURATION SETTINGS:\n\n$report_unmatched\n"; }
         else { print MAIL "All patrons' titles match the configuration settings.\n"; }
      }   
   } 
close(MAIL);


$tajmstemp = strftime "%Y%m%d-%H:%M:%S", localtime;
print LOGFILE "\nEND $tajmstemp\n-------------------------------------------------------------------------------------------------\n\n";
close (LOGFILE);
