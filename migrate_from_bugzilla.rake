# redMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# Bugzilla migration by Arjen Roodselaar, Lindix bv
#

desc 'Bugzilla migration script'

require 'active_record'
require 'iconv'
require 'pp'

module ActiveRecord
  namespace :redmine do
    task :migrate_from_bugzilla => :environment do

      module AssignablePk
        attr_accessor :pk
        def set_pk
          self.id = self.pk unless self.pk.nil?
        end
      end

      def self.register_for_assigned_pk(klasses)
        klasses.each do |klass|
          klass.send(:include, AssignablePk)
          klass.send(:before_create, :set_pk)
        end
      end

      register_for_assigned_pk([User, Project, Issue, IssueCategory, Attachment, Version])

      module BugzillaMigrate
        DEFAULT_STATUS = IssueStatus.default
        assigned_status = IssueStatus.find_by_id(7)
        organge_status = IssueStatus.find_by_id(8)
        red_status = IssueStatus.find_by_id(9)
        yellow_status = IssueStatus.find_by_id(10)
        green_status = IssueStatus.find_by_id(11)
        RELEASED_STATUS = IssueStatus.find_by_id(12)
        DISCARDED_STATUS = IssueStatus.find_by_id(13)

     
     STATUS_MAPPING = {
          "UNCONFIRMED" => DEFAULT_STATUS,
          "NEW" => DEFAULT_STATUS,
          "VERIFIED" => DEFAULT_STATUS,
          "ASSIGNED" => assigned_status,
          "REOPENED" => red_status,
          "RESOLVED" => yellow_status
        }

        priorities = IssuePriority.all(:order => 'id')
        PRIORITY_MAPPING = {
          "P5" => priorities[1], # low
          "P4" => priorities[2], # normal
          "P3" => priorities[3], # high
          "P2" => priorities[4], # urgent
          "P1" => priorities[5]  # immediate
        }
        DEFAULT_PRIORITY = PRIORITY_MAPPING["P2"]

        @trackernames = ['adaptive', 'corrective', 'perfective', 'preventive', 'uncategorized']
        TRACKER_FEATURE = Tracker.find_by_position(2)

#        reporter_role = Role.find_by_position(5)
#        developer_role = Role.find_by_position(4)
        manager_role = Role.find_by_position(3)
        DEFAULT_ROLE = manager_role

        CUSTOM_FIELD_TYPE_MAPPING = {
          0 => 'string', # String
          1 => 'int',    # Numeric
          2 => 'int',    # Float
          3 => 'list',   # Enumeration
          4 => 'string', # Email
          5 => 'bool',   # Checkbox
          6 => 'list',   # List
          7 => 'list',   # Multiselection list
          8 => 'date',   # Date
        }

        RELATION_TYPE_MAPPING = {
          0 => IssueRelation::TYPE_DUPLICATES, # duplicate of
          1 => IssueRelation::TYPE_RELATES,    # related to
          2 => IssueRelation::TYPE_RELATES,    # parent of
          3 => IssueRelation::TYPE_RELATES,    # child of
          4 => IssueRelation::TYPE_DUPLICATES  # has duplicate
        }

        BUGZILLA_ID_FIELDNAME = "Bugzilla-Id"
        QA_CONTACT_FIELDNAME = "QA-Contact"
	QA_CONTACT_SECOND_LEVEL_FIELDNAME = "QA-Contact (2nd level)"

        class BugzillaProfile < ActiveRecord::Base
          set_table_name :profiles
          set_primary_key :userid

          has_and_belongs_to_many :groups,
            :class_name => "BugzillaGroup",
            :join_table => :user_group_map,
            :foreign_key => :user_id,
            :association_foreign_key => :group_id

          def login
            login_name[0..29].gsub(/[^a-zA-Z0-9_\-@\.]/, '-')
          end

          def email
            if login_name.match(/^.*@.*$/i)
              login_name
            else
              "#{login_name}@foo.bar"
            end
          end

          def lastname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/)[-1]
          end

          def firstname
            s = read_attribute(:realname)
            return 'unknown' if(s.blank?)
            return s.split(/[ ,]+/).first
          end
        end

        class BugzillaCCers < ActiveRecord::Base
          set_table_name :cc
        end

        class BugzillaGroup < ActiveRecord::Base
          set_table_name :groups

          has_and_belongs_to_many :profiles,
            :class_name => "BugzillaProfile",
            :join_table => :user_group_map,
            :foreign_key => :group_id,
            :association_foreign_key => :user_id
        end

        class BugzillaProduct < ActiveRecord::Base
          set_table_name :products

          has_many :components, :class_name => "BugzillaComponent", :foreign_key => :product_id
          has_many :milestones, :class_name => "BugzillaMilestone", :foreign_key => :product_id
          has_many :versions, :class_name => "BugzillaVersion", :foreign_key => :product_id
          has_many :bugs, :class_name => "BugzillaBug", :foreign_key => :product_id
        end

        class BugzillaComponent < ActiveRecord::Base
          set_table_name :components
        end

        class BugzillaVersion < ActiveRecord::Base
          set_table_name :versions
        end

        class BugzillaMilestone < ActiveRecord::Base
          set_table_name :milestones
        end

        class BugzillaBug < ActiveRecord::Base
          set_table_name :bugs
          set_primary_key :bug_id

          belongs_to :product, :class_name => "BugzillaProduct", :foreign_key => :product_id
          has_many :descriptions, :class_name => "BugzillaDescription", :foreign_key => :bug_id
          has_many :attachments, :class_name => "BugzillaAttachment", :foreign_key => :bug_id
        end

        class BugzillaDependency < ActiveRecord::Base
          set_table_name :dependencies
        end

        class BugzillaDuplicate < ActiveRecord::Base
          set_table_name :duplicates
        end

        class BugzillaDescription < ActiveRecord::Base
          set_table_name :longdescs
          set_inheritance_column :bongo
          belongs_to :bug, :class_name => "BugzillaBug", :foreign_key => :bug_id

          def eql(desc)
            self.bug_when == desc.bug_when
          end

          def === desc
            self.eql(desc)
          end

          def text
            if self.thetext.blank?
              return nil
            else
              self.thetext
            end
          end
        end

        class BugzillaAttachment < ActiveRecord::Base
          set_table_name :attachments
          set_primary_key :attach_id

          has_one :attach_data, :class_name => 'BugzillaAttachData', :foreign_key => :id


          def size
            return 0 if self.attach_data.nil?
            return self.attach_data.thedata.size
          end

          def original_filename
            return self.filename
          end

          def content_type
            self.mimetype
          end

          def read(*args)
            if @read_finished
              nil
            else
              @read_finished = true
              return nil if self.attach_data.nil?
              return self.attach_data.thedata
            end
          end
        end

        class BugzillaAttachData < ActiveRecord::Base
          set_table_name :attach_data
        end

        class BugzillaKeywords < ActiveRecord::Base
          set_table_name :keywords
        end
 
        class BugzillaKeywordDefs < ActiveRecord::Base
          set_table_name :keyworddefs
          set_primary_key :id
        end

        def self.establish_connection(params)
          constants.each do |const|
            klass = const_get(const)
            next unless klass.respond_to? 'establish_connection'
            klass.establish_connection params
          end
        end

        def self.map_user(userid)
           return @user_map[userid]
        end

        def self.migrate_users
          puts
          print "Migrating profiles\n"
          $stdout.flush

          # bugzilla userid => redmine user pk.  Use email address
          # as the matching mechanism.  If profile exists in redmine,
          # leave it untouched, otherwise create a new user and copy
          # the profile data from bugzilla

          @user_map = {}
          BugzillaProfile.all(:order => :userid).each do |profile|
            profile_email = profile.email
            profile_email.strip!
            existing_redmine_user = User.find_by_mail(profile_email)
            if existing_redmine_user
              @user_map[profile.userid] = existing_redmine_user.id
            else
              # create the new user with its own fresh pk
              # and make an entry in the mapping
              user = User.new
              user.login = profile.login
              user.password = "bugzilla"
              user.firstname = profile.firstname
              user.lastname = profile.lastname
              user.mail = profile.email
              user.mail.strip!
              user.status = User::STATUS_LOCKED if !profile.disabledtext.empty?
              user.admin = true if profile.groups.include?(BugzillaGroup.find_by_name("admin"))
      	      unless user.save then
                puts "FAILURE saving user"
                puts "user: #{user.inspect}"
                puts "bugzilla profile: #{profile.inspect}"
                validation_errors = user.errors.collect {|e| e.to_s }.join(", ")
                puts "validation errors: #{validation_errors}"
              end
              @user_map[profile.userid] = user.id
            end
          end
          ### avoidance of duplicate user - manual hack fix!! 
          @user_map[145] = 343 # streitel
          @user_map[34] = 340 # pfaller
          @user_map[126] = 342 # kanis
          @user_map[155] = 344 # nils
          print '.'
          $stdout.flush
        end

        def self.migrate_products
          puts
          print "Migrating products"
          $stdout.flush

          #Project.destroy_all

          @project_map = {}
          @category_map = {}

          BugzillaProduct.find_each do |product|
            project = Project.new
            project.name = product.name
            project.description = product.description
            project.identifier = "#{product.name.downcase.gsub(/[^a-z0-9]+/, '-')[0..10]}-#{product.id}"
            project.save!

            @project_map[product.id] = project.id

            print '.'
            $stdout.flush

            product.milestones.each do |version|
              Version.create(:name => version.value, :project => project)
            end

            # Components
            product.components.each do |component|
              # assume all components get a new category

              category = IssueCategory.new(:name => component.name[0,30])
              #category.pk = component.id
              category.project = project
              uid = map_user(component.initialowner)
              category.assigned_to = User.first(:conditions => {:id => uid })
              category.save
              @category_map[component.id] = category.id
            end

            User.find_each do |user|
              membership = Member.new(
                :user => user,
                :project => project
              )
              membership.roles << DEFAULT_ROLE
              membership.save
            end
          end
        end

        def self.migrate_ccers()
            BugzillaCCers.find_by_sql("select * from cc").each do |cc|
	      if !@issue_map[cc.bug_id].nil?
	         watcher = Watcher.new(:watchable => Issue.find(@issue_map[cc.bug_id]), :user => User.find(map_user(cc.who)))
              	 watcher.save!
	      end
            end
        end

        def self.migrate_keywords_by_table() 
          puts
          print "Migrating keyword table"
          keyworddefs = {}
          BugzillaKeywordDefs.find_each do |keyworddef|
            keyworddefs[keyworddef.id] = keyworddef.name
          end

          BugzillaKeywords.find_by_sql("select * from keywords").each do |keyword|
            if !@issue_map[keyword.bug_id].nil?
              issue = @issue_map[keyword.bug_id]
              issue = Issue.find(issue)
              @trackers.each do |trackername, tracker|
                if keyworddefs[keyword.keywordid] == trackername
                  issue.tracker = tracker
                  issue.save!
                  print '.'
                  break
                end
              end
            end
          end
        end

        def self.migrate_issues()
          puts
          print "Migrating issues"

          # Issue.destroy_all
          @issue_map = {}

          # custom_field_bug_id = IssueCustomField.find_by_name(BUGZILLA_ID_FIELDNAME)
          custom_field_qa_contact = IssueCustomField.find_by_name(QA_CONTACT_FIELDNAME)

          BugzillaBug.find(:all, :order => "bug_id ASC").each  do |bug|
	    if !@project_map[bug.product_id].nil?
            #puts "Processing bugzilla bug #{bug.bug_id}"
            description = bug.descriptions.first.text.to_s

            # We also use the resolution to determine the new status
            bug_mapped_status = STATUS_MAPPING[bug.bug_status]
            if !bug_mapped_status 
              bug_mapped_status = DISCARDED_STATUS
              bug_mapped_status = RELEASED_STATUS if bug.resolution == "FIXED"
            end
  
         
            issue = Issue.new(
              :project_id => @project_map[bug.product_id],
              :subject => bug.short_desc,
              :description => description || bug.short_desc,
              :author_id => map_user(bug.reporter),
              :priority => PRIORITY_MAPPING[bug.priority] || DEFAULT_PRIORITY,
              :status => bug_mapped_status,
              :start_date => bug.creation_ts,
              :created_on => bug.creation_ts,
              :updated_on => bug.delta_ts
            )

            # Assign trackers to keyword saved
            issue.tracker = @trackers['uncategorized']
            if !@run_migrate_keywords_by_table
              @trackers.each do |trackername, tracker|
                  if bug.keywords.strip == trackername
                    issue.tracker = tracker
                    break
                  end
                end
            end

            # issue.category_id = @category_map[bug.component_id]
            if Issue.find_by_id(bug.bug_id).nil?
              issue.id = bug.bug_id
            else
              puts 
              print "Warning: Couldn't preserve original bug id #{bug.bug_id}, now "
	      bug_id_altered = 1
	    end

            issue.category_id =  @category_map[bug.component_id] unless bug.component_id.blank?
            issue.assigned_to_id = map_user(bug.assigned_to) unless bug.assigned_to.blank?
            version = Version.first(:conditions => {:project_id => @project_map[bug.product_id], :name => bug.target_milestone })
            issue.fixed_version = version

            issue.save!
	    if bug_id_altered
	       print "#{issue.id}"
	    end
            @issue_map[bug.bug_id] = issue.id


            bug.descriptions.each do |description|
              # the first comment is already added to the description field of the bug
              next if description === bug.descriptions.first
              journal = Journal.new(
                :journalized => issue,
                :user_id => map_user(description.who),
                :notes => description.text,
                :created_on => description.bug_when
              )
              journal.save!
            end


            # Additionally save the original bugzilla bug ID as custom field value.
            # Additionally save QA contact
            issue.custom_field_values = { custom_field_qa_contact.id => "#{map_user(bug.qa_contact)}" }
            issue.save_custom_field_values

            print '.'
            $stdout.flush
	    end
          end
        end

        def self.migrate_attachments()
          puts
          print "Migrating attachments"
          BugzillaAttachment.find_each() do |attachment|
            next if attachment.attach_data.nil?
	    if !@issue_map[attachment.bug_id].nil?
              a = Attachment.new :created_on => attachment.creation_ts
              a.file = attachment
              a.author = User.find(map_user(attachment.submitter_id)) || User.first
              a.container = Issue.find(@issue_map[attachment.bug_id])
              a.save

              print '.'
              $stdout.flush
            end
          end
        end

        def self.migrate_issue_relations()
          puts
          print "Migrating issue relations"
          BugzillaDependency.find_by_sql("select blocked, dependson from dependencies").each do |dep|
            if !@issue_map[dep.blocked].nil? && !@issue_map[dep.dependson].nil?
              rel = IssueRelation.new
              rel.issue_from_id = @issue_map[dep.blocked]
              rel.issue_to_id = @issue_map[dep.dependson]
              rel.relation_type = "blocks"
              rel.save
              print '.'
              $stdout.flush
            end
          end

          BugzillaDuplicate.find_by_sql("select dupe_of, dupe from duplicates").each do |dup|
            rel = IssueRelation.new
            rel.issue_from_id = @issue_map[dup.dupe_of]
            rel.issue_to_id = @issue_map[dup.dupe]
            rel.relation_type = "duplicates"
            rel.save
            print '.'
            $stdout.flush
          end
        end

        def self.create_custom_bug_id_field
           custom = IssueCustomField.find_by_name(BUGZILLA_ID_FIELDNAME)
           return if custom
           custom = IssueCustomField.new({:regexp => "",
                                          :position => 1,
                                          :name => BUGZILLA_ID_FIELDNAME,
                                          :is_required => false,
                                          :min_length => 0,
                                          :default_value => "",
                                          :searchable =>true,
                                          :is_for_all => true,
                                          :max_length => 0,
                                          :is_filter => true,
                                          :editable => true,
                                          :field_format => "string" })
           custom.save!

           Tracker.all.each do |t|
             t.custom_fields << custom
             t.save!
           end
        end

        def self.create_custom_qa_contact_field(fieldname)
          custom = IssueCustomField.find_by_name(fieldname)
          return if custom
          puts "Creating custom QA"
          custom = IssueCustomField.new({ :name => fieldname,
                                          :is_required => false,
                                          :is_for_all => true,
                                          :is_filter => true,
                                          :editable => true,
                                          :field_format => "user" })
          custom.save!

          Tracker.all.each do |t|
            t.custom_fields << custom
            t.save!
          end
        end

        def self.find_or_create_custom_trackers
          @trackers = {}
          @trackernames.each do |trackername|
            tracker = Tracker.find_by_name(trackername)
            if tracker.nil?
              tracker = Tracker.new(:name => trackername)
              tracker.save!
            end
            @trackers[trackername] = tracker
          end
        end

        puts
        puts "WARNING: Your Redmine data could be corrupted during this process."
        print "Are you sure you want to continue ? [y/N] "
        break unless STDIN.gets.match(/^y$/i)

        # Default Bugzilla database settings
        db_params = {:adapter => 'mysql2',
          :database => 'bugzilla',
          :host => 'localhost',
          :port => 3306,
          :username => 'root',
          :password => '',
          :encoding => 'utf8'}

        puts
        puts "Please enter settings for your Bugzilla database"
        [:adapter, :host, :port, :database, :username, :password].each do |param|
            print "#{param} [#{db_params[param]}]: "
            value = STDIN.gets.chomp!
            value = value.to_i if param == :port
            db_params[param] = value unless value.blank?
        end

	print "Is this data from bugzilla version 4 or above ? [y/N] "
	if STDIN.gets.match(/^y$/i)
	   @run_migrate_keywords_by_table = true
	else
	   @run_migrate_keywords_by_table = false
	end

        # Make sure bugs can refer bugs in other projects
        Setting.cross_project_issue_relations = 1 if Setting.respond_to? 'cross_project_issue_relations'

        # Turn off email notifications
        Setting.notified_events = []


        BugzillaMigrate.establish_connection db_params
	BugzillaMigrate.find_or_create_custom_trackers
        # BugzillaMigrate.create_custom_bug_id_field
        BugzillaMigrate.create_custom_qa_contact_field(QA_CONTACT_FIELDNAME)
        BugzillaMigrate.create_custom_qa_contact_field(QA_CONTACT_SECOND_LEVEL_FIELDNAME)
        BugzillaMigrate.migrate_users
        BugzillaMigrate.migrate_products
        BugzillaMigrate.migrate_issues
        BugzillaMigrate.migrate_keywords_by_table if @run_migrate_keywords_by_table
        BugzillaMigrate.migrate_ccers
        BugzillaMigrate.migrate_attachments
        BugzillaMigrate.migrate_issue_relations
      end
    end
  end
end

