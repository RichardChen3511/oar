package oarversion;
require Exporter;

my $OARVersion = "2.4.5";
my $OARName = "Thriller";

sub get_version(){
    return $OARVersion." (".$OARName.")";
}

return 1;
