/*
 * bootc-classes.js - variant A surfaces S10 of docs/compose-variant-a-plan.md.
 * PENDING (not wired, spec 2026-10-30): parked OUTSIDE the pve-manager deb
 * mirror because the deb ships no www/ tree; when S10 lands, this payload is
 * appended to pvemanagerlib.js through the pvemanagerlib.js.patch hunk (S9
 * wiring: Workspace button + ResourceTree section) - never as a standalone
 * file at the deb root.
 * Bootc guests have their OWN section; the LXC tree rendering is untouched.
 *
 * Classes:
 *   PVE.bootc.Templates - grid of published templates (pvect-ostree templates
 *                         view: stack, archive, compose source) + Create.
 *   PVE.bootc.Create    - compose-to-template creator: textarea editor ->
 *                         POST compose editor -> publish -> build log ->
 *                         relocation summary -> template pre-filled.
 *   PVE.bootc.Edit      - open the recorded YAML, compose-refresh.
 *   PVE.bootc.Status    - start/stop/shutdown/destroy against
 *                         nodes/{node}/bootc/{vmid} (Status API).
 */
Ext.define('PVE.bootc.Templates', {
    extend: 'Ext.panel.Panel',
    alias: ['widget.pveBootcTemplates'],

    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function () {
        let me = this;

        me.store = Ext.create('Ext.data.Store', {
            fields: ['archive', 'stack', 'imgref', 'ctime', 'compose'],
            autoLoad: true,
            proxy: {
                type: 'proxmox',
                url: `/nodes/${PVE.StateProvider.getSingleNode()}/bootc/templates`,
            },
        });

        me.grid = Ext.create('Ext.grid.Panel', {
            flex: 1,
            store: me.store,
            columns: [
                {
                    text: gettext('Template'),
                    dataIndex: 'archive',
                    flex: 1,
                },
                {
                    text: gettext('Image'),
                    dataIndex: 'imgref',
                    flex: 1,
                },
                {
                    text: gettext('Compose source'),
                    dataIndex: 'compose',
                    flex: 1,
                },
                {
                    text: gettext('Built'),
                    dataIndex: 'ctime',
                    renderer: Proxmox.Utils.render_timestamp,
                    width: 120,
                },
            ],
            buttons: [
                {
                    text: gettext('Create from Compose'),
                    iconCls: 'fa fa-ship',
                    handler: () => Ext.create('PVE.bootc.Create').show(),
                },
                {
                    text: gettext('Create Guest'),
                    iconCls: 'fa fa-cubes',
                    handler: () => Ext.create('PVE.bootc.Create', {
                        fromTemplate: true,
                    }).show(),
                },
            ],
        });

        me.items = [me.grid];
        me.callParent();
    },
});

Ext.define('PVE.bootc.Create', {
    extend: 'Ext.window.Window',
    alias: ['widget.pveBootcCreate'],

    modal: true,
    width: 760,
    layout: { type: 'vbox', align: 'stretch' },
    bodyPadding: 5,

    initComponent: function () {
        let me = this;

        me.yamlField = Ext.create('Ext.form.field.TextArea', {
            fieldLabel: gettext('docker-compose.yml'),
            height: 300,
            name: 'compose',
            flex: 1,
        });

        me.panel = Ext.create('PVE.panel.TaskProgressView', {
            hidden: true,
        });

        me.items = [
            me.yamlField,
            me.panel,
            {
                xtype: 'toolbar',
                items: [
                    {
                        text: gettext('Build & Publish'),
                        iconCls: 'fa fa-ship',
                        handler: () => me.publish(),
                    },
                ],
            },
        ];

        me.buttons = [{ text: gettext('Close'), handler: () => me.close() }];
        me.callParent();
    },

    // publish the compose stack through the storage plugin, then show the
    // build log + relocation summary and pre-fill the template name.
    publish: function () {
        let me = this;
        let stack = `bootc-${Date.now()}`; // the API names the stack when unset
        let url = '/nodes/' + PVE.StateProvider.getSingleNode() +
            `/bootc/compose/${stack}`;
        Proxmox.Utils.API2Request({
            method: 'POST',
            url: url,
            params: { compose: me.yamlField.getValue() },
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: (response) => {
                me.panel.start(response.result.data);
                me.panel.setHidden(false);
            },
        });
    },
});

Ext.define('PVE.bootc.Edit', {
    extend: 'Ext.window.Window',
    alias: ['widget.pveBootcEdit'],

    modal: true,
    width: 760,

    initComponent: function () {
        let me = this;

        me.yamlField = Ext.create('Ext.form.field.TextArea', {
            fieldLabel: gettext('docker-compose.yml'),
            height: 300,
            name: 'compose',
        });

        me.items = [
            me.yamlField,
            {
                xtype: 'toolbar',
                items: [
                    {
                        text: gettext('Refresh Guest'),
                        iconCls: 'fa fa-recycle',
                        handler: () => me.refresh(),
                    },
                ],
            },
        ];

        me.buttons = [
            {
                text: gettext('Rollback'),
                handler: () => me.rollback(),
            },
            { text: gettext('Close'), handler: () => me.close() },
        ];

        Proxmox.Utils.API2Request({
            url: `/nodes/${me.node}/bootc/${me.vmid}/compose`,
            failure: (response, opts) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: (response, opts) => me.yamlField.setValue(response.result.data),
        });

        me.callParent();
    },

    refresh: function () {
        let me = this;
        Proxmox.Utils.API2Request({
            method: 'POST',
            url: `/nodes/${me.node}/bootc/${me.vmid}/compose-refresh`,
            failure: (response, opts) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: (response, opts) => Ext.Msg.show({
                title: gettext('Refresh'),
                msg: response.result.statusText,
                icon: Ext.Msg.INFO,
            }),
        });
    },

    rollback: function () {
        let me = this;
        Proxmox.Utils.API2Request({
            method: 'POST',
            url: `/nodes/${me.node}/bootc/${me.vmid}/rollback`,
            failure: (response, opts) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
        });
    },
});

Ext.define('PVE.bootc.Status', {
    extend: 'Ext.panel.Panel',
    alias: ['widget.pveBootcStatus'],

    initComponent: function () {
        let me = this;

        me.store = Ext.create('Ext.data.Store', {
            fields: ['vmid', 'node', 'name', 'status'],
            autoLoad: true,
            proxy: {
                type: 'proxmox',
                url: `/nodes/${me.node ?? PVE.StateProvider.getSingleNode()}/bootc`,
            },
        });

        me.grid = Ext.create('Ext.grid.Panel', {
            store: me.store,
            columns: [
                { text: gettext('VMID'), dataIndex: 'vmid', width: 90 },
                { text: gettext('Name'), dataIndex: 'name', flex: 1 },
                { text: gettext('Status'), dataIndex: 'status', width: 110 },
                {
                    text: gettext('Actions'),
                    xtype: 'widgetcolumn', // keep the row actions flat
                    width: 180,
                    widget: {
                        xtype: 'toolbar',
                        items: [
                            {
                                text: gettext('Start'),
                                handler: (btn) => me.action(btn, 'start'),
                            },
                            {
                                text: gettext('Stop'),
                                handler: (btn) => me.action(btn, 'stop'),
                            },
                            {
                                text: gettext('Destroy'),
                                iconCls: 'fa fa-trash-o',
                                handler: (btn) => me.destroyGuest(btn),
                            },
                        ],
                    },
                },
            ],
        });

        me.items = [me.grid];
        me.callParent();
    },

    action: function (btn, action) {
        let me = this;
        let rec = btn.up('grid').getSelection()[0];
        if (!rec) return;
        Proxmox.Utils.API2Request({
            method: 'POST',
            url: `/nodes/${rec.data.node}/bootc/${rec.data.vmid}/${action}`,
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: () => me.store.reload(),
        });
    },

    destroyGuest: function (btn) {
        let me = this;
        let rec = btn.up('grid').getSelection()[0];
        if (!rec) return;
        Ext.Msg.confirm(gettext('Destroy'), `bootc guest ${rec.data.vmid}: are you sure?`,
            (button) => {
                if (button !== 'yes') return;
                Proxmox.Utils.API2Request({
                    method: 'DELETE',
                    url: `/nodes/${rec.data.node}/bootc/${rec.data.vmid}`,
                    failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                    success: () => me.store.reload(),
                });
            });
    },
});