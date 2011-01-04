Chef2Puppet
===========

This is the beginnings of a mechanism for converting Chef cookbooks
to Puppet classes and modules.  It is intended to work with Chef
recipes built largely using the DSL without resorting much to other
Ruby code.  It is in the mid-stages now and simply generates Puppet
classes with mostly correct syntax.  You will definitely need to
hand edit the resulting Puppet code, but hopefully not too much.

How it Works
------------

The script sets up a dummy environment in which the Chef DSL can
be evaluated.  Rather than doing anything, the evaluated code simply
prints out Puppet(ish) formatted classes that can then be edited
by hand to make them correct.  The goal is that you will need to
do a minimal amount of work on the output to make it clean, but
since Chef lets you use all the power of Ruby it's too large a task
to capture all possible intentions.

Output is all into a directory structure than can be copied to the
Puppet modules directory, including the original files and templates.
Inside of templates, an attempt is made to substitute node attribute
calls into Puppet-compatible ones.
