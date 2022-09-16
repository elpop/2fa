#!/usr/bin/perl
#=====================================================================#
# Program => ga_cli.pl (In Perl 5.0)                    version 1.0.0 #
#=====================================================================#
# Autor         => Fernando "El Pop" Romo          (pop@cofradia.org) #
# Creation date => 01/September/2022                                  #
#---------------------------------------------------------------------#
# Info => This program is a CLI version of the Google Authenticator   #
#         App.                                                        #
#---------------------------------------------------------------------#
# This code are released under the GPL 3.0 License. Any change must   #
# be report to the authors                                            #
#                     (c) 2022 - Fernando Romo                        #
#=====================================================================#
use strict;
use Auth::GoogleAuth;
use Barcode::ZBar;
use Convert::Base32;
use File::Copy;
use Getopt::Long;
use Google::ProtocolBuffers;
use Image::Magick;
use Imager::QRCode;
use MIME::Base64;
use Pod::Usage;

# Constants 
use constant {
    # Header for QR messages on export
    GAHEADER => 'otpauth-migration://offline?data=',
    # Text Colors
    FG_GREEN => "\033[32m",
    FG_RED   => "\033[31m",
    RESET    => "\033[0m",
};

# Definition of the Protocol Buffers generated by Google Authenticator Export Accounts options
Google::ProtocolBuffers->parse("
    syntax = \"proto2\";
    message GA {
        repeated Keys Index = 1;
        message Keys {
            required string    pass      = 1;
            required string    keyid     = 2;
            optional string    issuer    = 3;
            optional Algorithm algorithm = 4;
            optional DigitSize digits    = 5;
            optional OtpType   type      = 6;
            enum Algorithm  {
                ALGO_UNSPECIFIED = 0;
                SHA1             = 1;
                SHA256           = 2;
                SHA512           = 3;
                MD5              = 4;
            }
            enum DigitSize {
                DS_UNSPECIFIED = 0;
                SIX            = 1;
                EIGHT          = 2;
            }
            enum OtpType {
                OT_UNSPECIFIED = 0;
                HOTP           = 1;
                TOTP           = 2;
            }
         }
         optional int32 version = 2;
         optional int32 QRCount = 3;
         optional int32 QRIndex = 4;
     }",
     {create_accessors => 1}
);

# Work variables
my $work_dir = $ENV{'HOME'} . '/.ga_cli'; # keys directory
my %key_ring = ();
my %options = ();

# Command Line options
GetOptions(\%options,
           'import',
           'export',
           'clear',
           'verbose',
           'help|?',
);

# Load config File
if (-f "$work_dir\/keys") {
    %key_ring = do "$work_dir\/keys";
}

# Write Keys configuration
sub write_conf {
       
    # make a backup (just in case).
    if (-f "$work_dir\/keys") {
        move("$work_dir\/keys", "$work_dir\/keys.back");
    }
  
    # Create and write a conf file called "keys"
    open(CONF, ">:encoding(UTF-8)","$work_dir\/keys") or die "Can't create conf file: $!";
    print CONF "(\n";
    foreach my $issuer (sort { "\U$a" cmp "\U$b" } keys %key_ring) {
        print CONF "    '$issuer' => {\n";
        print CONF "        keyid     => '$key_ring{$issuer}{keyid}',\n";
        # convert the passwords in octal notation
        $key_ring{$issuer}{secret} =~ s/[\N{U+0000}-\N{U+FFFF}]/sprintf("\\%03o",ord($&))/eg;
        print CONF "        secret    => \"$key_ring{$issuer}{secret}\",\n";
        print CONF "        algorithm => $key_ring{$issuer}{algorithm},\n";
        print CONF "        digits    => $key_ring{$issuer}{digits},\n";
        print CONF "        type      => $key_ring{$issuer}{type},\n";
        print CONF "    },\n";
    }
    print CONF ");\n";
    close(CONF);
  
    print scalar(keys %key_ring) . " keys on key ring\n" if ($options{'verbose'});
} # End sub write_conf()

# Read the QR data and process keys
sub import_qr {
    my $qr_data = '';
    my @images = grep {/\.(jpg|jpeg|png)$/} @ARGV; # filter image files from command arguments
    
    # Clean key_ring
    %key_ring = () if ($options{'clear'});
    
    #Internal function to process Data 
    sub _process_data {
        my $qr_data_ref = shift;
      
        # Check for "otpauth-migration://offline" in the QR info
        if ($$qr_data_ref =~ /^otpauth-migration:\/\/offline/) {
          
            # only take the MIME Data on the QR message
            my ($data) = $$qr_data_ref =~/data=(.*)/;
          
            # URL Decode
            $data =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
      
            # Decode Base64 Info
            my $mime_data = decode_base64($data);
        
            # Process Protocol Buffers from de MIME Base64 Data
            my $protocol_buffer = GA->decode("$mime_data");
            
            foreach my $ref (@{$protocol_buffer->{Index}}) {
              
                # Assign values to the key ring
                if ($ref->{issuer} ne '') {
                    $key_ring{$ref->{issuer}}{secret}    = $ref->{pass};
                    $key_ring{$ref->{issuer}}{keyid}     = $ref->{keyid};
                    $key_ring{$ref->{issuer}}{algorithm} = $ref->{algorithm};
                    $key_ring{$ref->{issuer}}{digits}    = $ref->{digits};
                    $key_ring{$ref->{issuer}}{type}      = $ref->{type};
                    print "    $ref->{issuer}\n" if ($options{'verbose'});
                }
                else {
                    $key_ring{$ref->{keyid}}{secret}    = $ref->{pass};
                    $key_ring{$ref->{keyid}}{keyid}     = $ref->{keyid};
                    $key_ring{$ref->{keyid}}{algorithm} = $ref->{algorithm};
                    $key_ring{$ref->{keyid}}{digits}    = $ref->{digits};
                    $key_ring{$ref->{keyid}}{type}      = $ref->{type};
                    print "    $ref->{keyid}\n" if ($options{'verbose'});
                }
            }
        }
        # Check for "otpauth://totp/" in the QR info for add a single key
        elsif ($$qr_data_ref =~ /^otpauth:\/\/totp/) {

            # Obtain values
            my ($keyid, $secret32, $issuer) = $$qr_data_ref =~ /totp\/.*?\:(.*)\?secret\=(.*)\&issuer=(.*)/;

            # if have minimun info to add key
            if ($keyid && $secret32) {

                # Decode de Base32 pass
                my $secret = decode_base32( $secret32);
               
                # Assign values to the key ring
                if ($issuer ne '') {
                    $key_ring{$issuer}{secret}    = $secret;
                    $key_ring{$issuer}{keyid}     = $keyid;
                    $key_ring{$issuer}{algorithm} = 1;
                    $key_ring{$issuer}{digits}    = 1;
                    $key_ring{$issuer}{type}      = 2;
                    print "    $issuer\n" if ($options{'verbose'});
                }
                else {
                    $key_ring{$keyid}{secret}    = $secret;
                    $key_ring{$keyid}{keyid}     = $keyid;
                    $key_ring{$keyid}{algorithm} = 1;
                    $key_ring{$keyid}{digits}    = 1;
                    $key_ring{$keyid}{type}      = 2;
                    print "    $keyid\n" if ($options{'verbose'});
                }
            }
            else {
                print "Error: No account to add to key ring\n";
            }
        }
        else {
            print "Error: No Google Authenticator Export Data found\n";
        }
    } # end sub _process_data()
    
    # create work directory if not exists
    unless (-f $work_dir) {
        mkdir($work_dir);
    }
    
    # Process if exists the argument with a image filename 
    if ($#images >=0) {
        
        # Process images
        foreach my $image (@images) {
            
            print "$image\n" if ($options{'verbose'});
    
            # Prepare to Read the QR using ZBar libs
            my $scanner = Barcode::ZBar::ImageScanner->new();
            $scanner->parse_config("enable");
        
            # Use ImageMagick to obtain image properties
            my $magick = Image::Magick->new();
            $magick->Read($image) && die;
            my $raw = $magick->ImageToBlob(magick => 'GRAY', depth => 8);
        
            # Set ZBar reader and read image
            my $image = Barcode::ZBar::Image->new();
            $image->set_format('Y800');
            $image->set_size($magick->Get(qw(columns rows)));
            $image->set_data($raw);
            my $n = $scanner->scan_image($image);
        
            # Read QR Data
            foreach my $symbol ($image->get_symbols()) {
                ($qr_data) = $symbol->get_data();
                # Process the Protocol Buffer Data
                _process_data(\$qr_data);
            }
            undef($image);
        }        
        write_conf();
    }
    # If you don't give any file, print help
    else {
        print "Usage:\n";
        print "    ./ga_cli.pl -import \[image_file(.png|.jpg)\]\n";
    }    
} # End sub import_qr()

# export Keys to QR for load in Google Authenticator
sub export_qr {
   
    # Date to put on export QR files
    sub _date {
        my ($year, $month, $day) = (localtime( time() ))[5,4,3];
        $year = $year + 1900;
        $month += 1;
        return sprintf("%04d%02d%02d",$year,$month,$day);
    } # End sub _date()
   
    # Obtain keys to process
    my $total_keys = scalar(keys %key_ring);
    my $images_count = int($total_keys / 10);
    my %export_ring = ( 'version' => 1,
                        'QRCount' => 1,
                        'QRIndex' => 0, );
    my $key_counter = 0;
    my $current = 1;

    if ( ($total_keys % 10) > 0) {
        $images_count++;
    }
    $export_ring{QRCount} = $images_count;
    
    # If have keys to process
    if ($total_keys > 0) {
    
        # Load Protocol Buffer Array to process
        foreach my $issuer (sort { "\U$a" cmp "\U$b" } keys %key_ring) {
            $key_counter++;
            push @{$export_ring{'Index'}},
                 ({
                  'issuer'    => "$issuer",
                  'keyid'     => "$key_ring{$issuer}{keyid}",
                  'pass'      => "$key_ring{$issuer}{secret}",
                  'algorithm' => $key_ring{$issuer}{algorithm},
                  'digits'    => $key_ring{$issuer}{digits},
                  'type'      => $key_ring{$issuer}{type},
                 });
        
            # Generate QR each 10 keys    
            if ( ( ($key_counter % 10) == 0 )
                || ($key_counter == $total_keys) ) {
                
                # Process Protocol Buffers from de MIME Base64 Data
                my $protocol_buffer = GA->encode(\%export_ring);
        
                # Encode MIME Base64                
                my $mime_data = encode_base64($protocol_buffer);
                
                # URL Encode
                $mime_data =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
                $mime_data =~ s/\%0A//g; # avoid new line
                
                # generate QR image
                my $qrcode = Imager::QRCode->new(
                        size          => 4,
                        margin        => 1,
                        version       => 1,
                        level         => 'M',
                        casesensitive => 1,
                        lightcolor    => Imager::Color->new(255, 255, 255),
                        darkcolor     => Imager::Color->new(0, 0, 0),
                );
                my $img = $qrcode->plot( GAHEADER . "$mime_data");
                my $qr_file = sprintf("export_keys_%08d_%02d_of_%02d.jpg", _date(), $current, $images_count);
                $img->write(file => "$qr_file");
                
                # Show progress
                print "$qr_file\n" if ($options{'verbose'});
                
                # Clean Up the has for the next 10 keys
                $export_ring{'Index'} = ();
                $export_ring{QRIndex} = $current++; # Next batch number
            }
        }
        # Clean key_ring
        if ($options{'clear'}) {
            %key_ring = ();
            write_conf();
        }
    }
    else {
        print "Error: No keys to process\n";
    }
} # End sub export_qr()

sub otp {

    # Show Green or Red Text if the timer change
    sub _semaphore {
        my ($seconds) = (localtime( time() ))[0];
        my $aux = $seconds % 30;
        my $color = FG_RED;
        if ($aux <= 25) {
           $color = FG_GREEN;
        }
        return $color;
    } # End sub _semaphore()
   
    # Generate OTP
    foreach my $issuer (sort { "\U$a" cmp "\U$b" } keys %key_ring) {
        my $auth = Auth::GoogleAuth->new({
               secret => "$key_ring{$issuer}{secret}",
               issuer => "$issuer",
               key_id => "$key_ring{$issuer}{key_id}",
           });
        $auth->secret32( encode_base32( $auth->secret() ) );
        my $out = sprintf( "%30s " . _semaphore() . " %06d" . RESET ."\n", $issuer, $auth->code() );
        
        # Filter output 
        if ($ARGV[0] ne '' ) {
            if ($issuer =~ /$ARGV[0]/i) {
               print $out;
            }
        }
        else {
            print $out;
        }
        $auth->clear();
    }
} # End sub otp()

#-----------#
# Main body #
#-----------#

if ($options{'help'}) {
    pod2usage(-exitval => 0, -verbose => 1);
    pod2usage(2);
}
elsif ($options{'import'}) {
    import_qr();
}
elsif ($options{'export'}) {
    export_qr();
}
# if have valid keys, process
elsif ( scalar(keys %key_ring) > 0 ) {
    # Generate OTP
    otp();
}
else {
    print "Error: No keys found\n";
}

# Help info for use with Pod::Usage
__END__

=head1 NAME

ga_cli.pl

=head1 SYNOPSIS

ga_cli.pl [options] {file ...}

=head1 OPTIONS

=over 8

=item B<None>

Show the TOTP of each account.

ga_cli.pl

    OpenEnchilada  972144
    
=item B<-import or -i>

Import given QR image file:

ga_cli.pl -import export_accounts_sample.jpg

The QR image can be the full Google Authenticator Export Set or a single account for add to the key ring

=item B<-export or -e>

Create QR images for export to Googla Authenticator App:

ga_cli.pl -export

=item B<-clear or -c>

Delete the key ring, works with -import or -export options.
When use -import, Init the key ring an load new values.
With -export, generate the QR images and delete the key ring.

=item B<-verbose or -v>

Show progress when using -import or -export options

=item B<-help or -h or -?>

Show this help

=back 

=head1 DESCRIPTION

B<ga_cli.pl> This program is a CLI version of the Google Authenticator App.   

=cut
