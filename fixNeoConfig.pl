# Perl 5 script to update a Neo4J configuration file's cluster node and cache information settings.
# It accepts an input config file and writes the modified version back to a specified target location.
#
# selliott@microsoft.com v2016.07.21.B
#
# Expected arguments:
#    1. port number -- communication port on each VM
#    2. comma-separated list of node IPs -- internal IPs for each of the VMS in this cluster
#    3. IP for this VM
#    4. Memory Percentage to use for cache -- an integer 0..100 indicating percentage of free
#       memory to use for caching.  Note: passing a negative value will leave the setting from
#       the input file unchanged.
#    5. inputConfig  -- path to file to use an input config to be modified by this script.
#    6. outputConfig -- path at which to write the modified config, usually /etc/neo4j/neo4j.conf
#
# e.g., perl fixconfig.pl 5300 '10.1.2.4,10.1.2.5,10.1.2.6' 10.1.2.5 55 ./neo4j.before.conf /etc/neo4j/neo4j.conf
#

use strict;
use File::Basename qw(dirname);
use File::Path qw(make_path);

my ($port,$ipList,$localIP,$CachePercentage, $inputConfigFile, $outputConfigFile) = @ARGV;

my @OutputLines = ();

# Build the content for the revised config file
open(INCONFIG, "< $inputConfigFile");

while(<INCONFIG>) {
        my $outline = $_;
        if (m/^ha.initial_hosts=/) {
                # build the node list
                my @nodes = split(',', $ipList);
                my $nodeList = join(":$port,", @nodes) . ":$port";
                $outline = "ha.initial_hosts=$nodeList\n";
                }
        elsif (m/^ha.host.data=/) {
                $outline = "ha.host.data=${localIP}:6000\n";
                }
        elsif (m/^ha.host.coordination=/) {
                $outline = "ha.host.coordination=${localIP}:${port}\n";
                }
        elsif (m/^ha.server_id=/) {
                # assume this server is always in the complete IP list and use it's orginal position therein.
                my @IPs = split(',', $ipList);
                my $idx = 0;  # final range will be 1..n
                for my $ip (@IPs) {
                        $idx++;
                        last if ($ip eq $localIP);
                }
                $outline = "ha.server_id=$idx\n";
                }
        elsif (m/^[#]*dbms.memory.pagecache.size=/ && $CachePercentage ge 0) {
                # calculate the cache size as % of free memory, let's use MB to try to be more precise on small machines.
                my %free = GetFreeMemory();
                my $cacheSize = int($free{'MB'} * ($CachePercentage * .01));
                $outline = "dbms.memory.pagecache.size=" . $cacheSize . "m\n";
                }

        push(@OutputLines, $outline);
}
close(INCONFIG);

#TODO: make a backup of the existing output config  file

# Ensure that the target's directory structure exists
my @parts = make_path(dirname($outputConfigFile));

# Write the updated config file to the target location.
open(OUTCONFIG, ">$outputConfigFile");
print OUTCONFIG @OutputLines;
close OUTCONFIG;
#print @OutputLines;
# END

# Return a hash of the Memory Free value from /proc/meminfo.
# Hash keys are 'KB', 'MB' and 'GB' expressing free memory in those units.

sub GetFreeMemory {
        open CMD,"cat /proc/meminfo |";
        my %sizes = {};

        while(<CMD>) {
                if (m/^MemFree:\s+(\d+)\s(kB|mB|gB)\s*$/) {
                        my $amtInKB = 0 + $1;
                        if ($2 eq 'mB') {
                                $amtInKB *= 1024;
                                }
                        elsif($2 eq 'gB') {
                                $amtInKB *= (1024 * 1024);
                        }

                        $sizes{'KB'} = $amtInKB;
                        $sizes{'MB'} = $sizes{'KB'} / 1024;
                        $sizes{'GB'} = $sizes{'MB'} / 1024;
                        #print $amtInKB; print $sizes{'GB'};
                        last;
                };
        }
        close(CMD);
        return %sizes;
}
